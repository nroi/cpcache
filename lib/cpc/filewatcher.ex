defmodule Cpc.Filewatcher do
  require Logger
  use GenServer
  @interval 5

  # Watches the given file and informs the caller when it has grown.

  def start_link(receiver, filename, max_size) do
    GenServer.start_link(__MODULE__, [receiver, filename, max_size])
  end

  def init({receiver, filename, max_size}) do
    Logger.debug "Init Filewatcher for file #{filename}"
    :erlang.send_after(@interval, self(), :timer)
    {:ok, {filename, 0, max_size, receiver}}
  end

  def handle_info(:timer, state = {filename, prev_size, max_size, receiver}) do
    case File.stat!(filename).size do
      ^prev_size ->
        :erlang.send_after(@interval, self(), :timer)
        {:noreply, state}
      ^max_size ->
        :ok = GenServer.cast(receiver, {:file_complete, {filename, prev_size, max_size}})
        {:stop, :normal, nil}
      new_size when new_size > prev_size ->
        :ok = GenServer.cast(receiver, {:filesize_increased, {filename, prev_size, new_size}})
        :erlang.send_after(@interval, self(), :timer)
        {:noreply, {filename, new_size, max_size, receiver}}
    end
  end
end
