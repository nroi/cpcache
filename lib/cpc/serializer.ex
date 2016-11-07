defmodule Cpc.Serializer do
  use GenServer
  require Logger

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def handle_info({from, :state?, filename}, state = %{}) do
    # the downloader has received a GET request which is neither a database nor a locally
    # available file. Hence, it needs to check if someone is already downloading this file.
    filename_status = case state[filename] do
      nil -> :unknown
      content_length -> {:downloading, content_length}
    end
    send from, filename_status
    # if the filename state is unknown, it will start downloading the file, informing us of the
    # content length. No other downloads will be started while we wait for the content-length to
    # arrive.
    case filename_status do
      :unknown ->
        receive do
          {^from, :content_length, {filename, content_length}} ->
            {:noreply, Map.put(state, filename, content_length)}
        after 3000 ->
            raise "Expected an answer within 3 secs"
        end
      _ -> {:noreply, state}
    end
  end

  def handle_cast({:download_completed, filename}, state = %{}) do
    Logger.info "Download completed: #{filename}"
    {:noreply, Map.delete(state, filename)}
  end


end
