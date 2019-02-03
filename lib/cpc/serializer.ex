defmodule Cpc.Serializer do
  use GenServer
  require Logger

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(args) do
    # default implementation to avoid warning.
    {:ok, args}
  end

  def handle_info({from, :state?, filename}, pidfnref) do
    # The downloader has received a GET request which is neither a database nor a locally
    # available file. Hence, it needs to check if someone is already downloading this file.
    downloading =
      Enum.any?(pidfnref, fn
        {_from, ^filename, _ref} -> true
        _ -> false
      end)

    filename_status =
      case downloading do
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
          ref = :erlang.monitor(:process, from)
          [{from, filename, ref} | pidfnref]

        :downloading ->
          pidfnref

        :invalid_path ->
          pidfnref
      end

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, status}, pidfnref) do
    :erlang.demonitor(ref)
    _ = Logger.debug("Process is down, remove from list of downloading processes.")

    ongoing_downloads =
      Enum.filter(pidfnref, fn
        {^pid, _filename, ^ref} -> false
        _ -> true
      end)

    case status do
      :normal -> Logger.debug("Process #{inspect(pid)} has ended with status normal.")
      status -> Logger.error("Process #{inspect(pid)} has ended with status #{inspect(status)}.")
    end

    {:noreply, ongoing_downloads}
  end

  def handle_cast({:download_ended, filename, pid}, pidfnref) do
    {ended_downloads, ongoing_downloads} =
      Enum.split_with(pidfnref, fn
        {^pid, ^filename, _ref} -> true
        _ -> false
      end)

    case ended_downloads do
      [{_, filename, ref}] ->
        Logger.info("Download ended: #{filename}")
        :erlang.demonitor(ref)

      _ ->
        :ok
    end

    {:noreply, ongoing_downloads}
  end
end
