defmodule Cpc.Filewatcher do
  require Logger
  use GenServer
  @interval 5

  # Watches the given file and informs the caller when it has grown.

  def start_link(receiver, filename, max_size, start_size \\ 0) do
    GenServer.start_link(__MODULE__, {receiver, filename, max_size, start_size})
  end

  def init({receiver, filename, max_size, start_size}) do
    Logger.debug("Init Filewatcher for file #{filename}")
    send(self(), :init)
    {:ok, {filename, start_size, max_size, receiver}}
  end

  def handle_info(:init, {filename, start_size, max_size, receiver}) do
    loop({filename, start_size, max_size, start_size, receiver})
  end

  defp loop(args = {filename, prev_size, max_size, start_size, receiver}) do
    if !Process.alive?(receiver) do
      # If the receiver died, there is no longer any reason to inform it of file changes.
      # Note that the receiver is the parent, hence this wouldn't be necessary if we were
      # to use a timer with message passing rather than a loop. However, the message passing
      # approach proved too inefficient with intervals as low as 5 ms.
      exit(:normal)
    end

    case File.stat!(filename).size do
      ^prev_size ->
        # _ = Logger.debug("File size has not increased. Current file size: #{prev_size}. Waiting…")
        :timer.sleep(@interval)
        loop(args)

      ^max_size ->
        _ = Logger.debug("File is complete.")
        :ok = GenServer.cast(receiver, {:file_complete, {filename, prev_size, max_size}})
        {:stop, :normal, nil}

      new_size when new_size > prev_size ->
        # If this is the first time the start_size threshold was exceeded, we report start_size as
        # the previous size.
        clean_prev_size = max(start_size, prev_size)

        :ok =
          GenServer.cast(receiver, {:filesize_increased, {filename, clean_prev_size, new_size}})

        :timer.sleep(@interval)
        loop({filename, new_size, max_size, start_size, receiver})

      new_size when new_size < prev_size ->
        # This state can occur when the specified start_size is larger than the initial file size.
        :timer.sleep(@interval)
        loop({filename, prev_size, max_size, start_size, receiver})
    end
  end
end
