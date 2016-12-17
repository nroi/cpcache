defmodule Cpc.Serializer do
  use GenServer
  require Logger

  def start_link(name) do
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  def init(state = %{}) do
    {:ok, _} = :timer.send_interval(5000, :debug)
    {:ok, state}
  end

  def handle_info({from, :state?, filename}, state = %{}) do
    # The downloader has received a GET request which is neither a database nor a locally
    # available file. Hence, it needs to check if someone is already downloading this file.
    filename_status = case state[filename] do
      nil -> :unknown
      content_length -> {:downloading, content_length}
    end
    send from, filename_status
    # If the filename state is unknown, it will start downloading the file, informing us of the
    # content length. No other downloads will be started while we wait for the content-length to
    # arrive.
    case filename_status do
      :unknown ->
        receive do
          {^from, :content_length, {filename, content_length}} ->
            {:noreply, Map.put(state, filename, content_length)}
          {^from, :not_found} ->
            # Was not able to GET this file (server replied 404)
            {:noreply, state}
          {^from, :complete} ->
            # We have previously assumed that the locally stored file is incomplete, but it turns
            # out the file was already complete. Now new download is started, state remains
            # unchanged.
            {:noreply, state}
        after 5000 ->
            raise "Expected an answer within 5 seconds."
        end
      _ -> {:noreply, state}
    end
  end

  def handle_info(:debug, state) do
    Logger.debug "Serializer state: #{inspect state}"
    {:noreply, state}
  end

  def handle_cast({:download_ended, filename}, state = %{}) do
    Logger.info "Download ended: #{filename}"
    {:noreply, Map.delete(state, filename)}
  end

end
