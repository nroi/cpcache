defmodule Cpc.Serializer do
  use GenServer
  require Logger

  def start_link(name) do
    GenServer.start_link(__MODULE__, [], name: name)
  end

  def handle_info({from, :state?, filename}, pidfnref) do
    # The downloader has received a GET request which is neither a database nor a locally
    # available file. Hence, it needs to check if someone is already downloading this file.
    downloading = Enum.any?(pidfnref, fn
      {_from, ^filename, _ref} -> true
      _                        -> false
    end)
    filename_status = case downloading do
      true -> :downloading
      false -> :unknown
    end
    send from, filename_status
    new_state = case filename_status do
      :unknown ->
        # the requesting process will initiate the download, hence we note that the file is being
        # downloaded.
        ref = :erlang.monitor(:process, from)
        [{from, filename, ref} | pidfnref]
       :downloading ->
         pidfnref
    end
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, pid, status}, pidfnref) do
    :erlang.demonitor(ref)
    ongoing_downloads = Enum.filter(pidfnref, fn
      {^pid, _filename, ^ref} -> false
      _                       -> true
    end)
    case status do
      :normal -> Logger.debug "Process #{inspect pid} has ended with status normal."
      status -> Logger.error "Process #{inspect pid} has ended with status #{inspect status}."
    end
    {:noreply, ongoing_downloads}
  end

  def handle_cast({:download_ended, filename, pid}, pidfnref) do
    {ended_downloads, ongoing_downloads} = Enum.partition(pidfnref, fn
      {^pid, ^filename, _ref} -> true
      _                       -> false
    end)
    case ended_downloads do
      [{_, filename, ref}] ->
        Logger.info "Download ended: #{filename}"
        :erlang.demonitor(ref)
      _ -> :ok
    end
    {:noreply, ongoing_downloads}
  end

end
