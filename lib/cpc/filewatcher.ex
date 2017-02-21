defmodule Cpc.Filewatcher do
  require Logger
  use GenServer
  @interval 5
  @timeout "3s" # After GET request, wait max. 3 seconds for file to appear.

  # Watches the given file and informs the caller when it has grown.

  def start_link(receiver, filename, max_size, start_size \\ 0) do
    GenServer.start_link(__MODULE__, {receiver, filename, max_size, start_size})
  end

  def init({receiver, filename, max_size, start_size}) do
    Logger.debug "Init Filewatcher for file #{filename}"
    send self(), :init
    {:ok, {filename, start_size, max_size, receiver}}
  end

  def handle_info(:init, {filename, start_size, max_size, receiver}) do
    Logger.debug "Wait until file #{filename} exists…"
    :ok = waitforfile(filename)
    Logger.debug "File exists."
    loop({filename, start_size, max_size, start_size, receiver})
  end

  defp loop(args = {filename, prev_size, max_size, start_size, receiver}) do
    case File.stat!(filename).size do
      ^prev_size ->
        :timer.sleep(@interval)
        loop(args)
      ^max_size ->
        :ok = GenServer.cast(receiver, {:file_complete, {filename, prev_size, max_size}})
        {:stop, :normal, nil}
      new_size when new_size > prev_size ->
        # If this is the first time the start_size threshold was exceeded, we report start_size as
        # the previous size.
        clean_prev_size = max(start_size, prev_size)
        :ok = GenServer.cast(receiver, {:filesize_increased, {filename, clean_prev_size, new_size}})
        :timer.sleep(@interval)
        loop({filename, new_size, max_size, start_size, receiver})
      new_size when new_size < prev_size ->
        # This state can occur when the specified start_size is larger than the initial file size.
        :timer.sleep(@interval)
        loop({filename, prev_size, max_size, start_size, receiver})
    end
  end

  def waitforfile(filepath) do
    case System.cmd("/usr/bin/timeout", [@timeout, "/usr/bin/waitforfile", filepath]) do
      {"", 0} -> :ok
      {"", 1} -> :invalid_filepath
      {"", 2} -> :invalid_filepath
      {"", 124} -> :timeout
    end
  end

end
