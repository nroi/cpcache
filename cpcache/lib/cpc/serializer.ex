defmodule Cpc.Serializer do
  use GenServer
  require Logger

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(args) do
    # default implementation to avoid warning.
    {:ok, args}
  end

  @impl true
  def handle_info({from, :state?, filename}, pidfnref) do
    # The downloader has received a GET request for a file which is neither a database nor a locally
    # available file. Hence, it needs to check if someone is already downloading this file.
    downloading_entry =
      Enum.find(pidfnref, fn
        {_from, ^filename, [_refs]} -> true
        _ -> false
      end)

    is_downloading? = !!downloading_entry

    filename_status =
      case is_downloading? do
        true ->
          :downloading

        false ->
          # Create file to avoid race conditions:
          # The Downloader process will append to an existing file, other processes can
          # stream from this file. If the file were created by the Downloader process,
          # other processes might attempt to read from a non-existing file.
          _ = Logger.debug("Attempt to touch file #{filename}")

          case File.touch(filename) do
            :ok ->
              :unknown

            _ ->
              # This case is caused sometimes by wrong file permissions, but also sometimes by get requests to
              # filenames that contain directories which do not exist in the local file system.
              # We chose to return :invalid_path instead of raising because sometimes, this is caused by malicious bots
              # which scan for security vulnerabilities (e.g. looking for certain php files). We don't want to
              # throw the entire stacktrace just because of such regular occurring events.
              Logger.info("Unable to access file: #{filename}")
              :invalid_path
          end
      end

    send(from, filename_status)

    new_state =
      case filename_status do
        :unknown ->
          # the requesting process will initiate the download, hence we note that the file is being
          # downloaded.
          ref = Process.monitor(from)

          # We mark this ref as :primary to reveal that this ref is associated with the process that originally
          # started the download process (as opposed to other processes that do not initiate a new download process
          # with the remote mirror).
          new_entry = {:primary, ref}
          Logger.debug("Will mark process #{inspect(from)} as primary.")
          [{from, filename, [new_entry]} | pidfnref]

        :downloading ->
          # We want to be able to share one download (i.e., one connection to a remote mirror) by multiple clients.
          # We also want to abort the connection to the remote mirror when all downloading clients have closed their
          # socket connection. To achieve this, we must keep track of *all* clients that depend on this file being
          # downloaded from the remote mirror. Otherwise, if we were to close the connection to the remote mirror
          # as soon as the client that originally initiated this connection closes its connection, we might have
          # other clients with stalling downloads.
          ref = Process.monitor(from)
          new_entry = {:secondary, ref}
          {from, filename, _refs} = downloading_entry

          Enum.map(pidfnref, fn
            {^from, ^filename, refs} -> {from, filename, [new_entry | refs]}
            other -> other
          end)

        :invalid_path ->
          pidfnref
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, status}, pidfnref) do
    Process.demonitor(ref)
    _ = Logger.debug("Process is down, remove from list of downloading processes.")

    pidfnref =
      Enum.filter(pidfnref, fn
        {^pid, _filename, _refs} -> false
        _ -> true
      end)

    tmp_pidfnref =
      Enum.map(pidfnref, fn
        {pid, filename, refs} ->
          new_refs = Enum.filter(refs, fn {_, existing_ref} -> existing_ref != ref end)
          {pid, filename, new_refs}
      end)

    {no_dependencies_left, ongoing_downloads} =
      Enum.split_with(tmp_pidfnref, fn
        {_pid, _filename, []} ->
          # We assert that the ref list cannot be empty since the process that initiated the download should always
          # be the last process that goes DOWN (of all processes that depend on the same file).
          # Since we already filter all entries of pidfnref where the pid matches the pid of the process that just went
          # down, this case must not happen.
          raise("Unexpected empty list of refs.")

        {_pid, _filename, [{:primary, _ref}]} ->
          true

        _ ->
          false
      end)

    Enum.each(no_dependencies_left, fn {pid, _filename, _refs} ->
      GenServer.cast(pid, :no_dependencies_left)
    end)

    case status do
      :normal -> Logger.debug("Process #{inspect(pid)} has ended with status normal.")
      status -> Logger.error("Process #{inspect(pid)} has ended with status #{inspect(status)}.")
    end

    {:noreply, ongoing_downloads}
  end

  @impl true
  def handle_call(:client_closed, {from_pid, _tag}, pidfnref) do
    num_clients =
      Enum.find_value(pidfnref, fn
        {^from_pid, _filename, refs} -> Enum.count(refs)
        _ -> false
      end)

    if num_clients && num_clients > 1 do
      _ =
        Logger.debug(
          "Cannot close connection yet: #{num_clients - 1} other processes need this connection."
        )

      {:reply, :wait_for_signal, pidfnref}
    else
      _ = Logger.debug("Signal to client_request that it's safe to close its connection.")
      {:reply, :ok, pidfnref}
    end
  end

  @impl true
  def handle_cast({:download_ended, filename, pid}, pidfnref) do
    {ended_downloads, ongoing_downloads} =
      Enum.split_with(pidfnref, fn
        {^pid, ^filename, _refs} -> true
        _ -> false
      end)

    case ended_downloads do
      [{_, filename, refs}] ->
        Logger.info("Download ended: #{filename}")
        Enum.each(refs, fn {_, ref} -> Process.demonitor(ref) end)

      _ ->
        :ok
    end

    {:noreply, ongoing_downloads}
  end
end
