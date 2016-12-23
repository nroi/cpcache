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
    send self, :init
    {:ok, {filename, 0, max_size, receiver}}
  end

  def handle_info(:init, state = {filename, 0, _max_size, _receiver}) do
    :ok = wait_until_file_exists(filename)
    :erlang.send_after(@interval, self, :timer)
    {:noreply, state}
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

  defp setup_port(filename) do
    cmd = "/usr/bin/inotifywait"
    args = ["-q", "-m", "--format", "%e %f", "-e", "create", filename]
    _ = Port.open({:spawn_executable, cmd}, [{:args, args}, :stream, :binary, :exit_status,
                                         :hide, :use_stdio, :stderr_to_stdout])
  end

  defp wait_until_recvd(expected_output, filepath) do
    receive do
        {port, {:data, ^expected_output}} ->
          {:os_pid, pid} = :erlang.port_info(port, :os_pid)
          {"", 0} = System.cmd("/usr/bin/kill", [to_string(pid)])
          true = Port.close(port)
          :ok
        {_port, {:data, m = "CREATE " <> _}} ->
          Logger.debug "Ignored: #{inspect m}"
          wait_until_recvd(expected_output, filepath)
        msg ->
          raise "Unexpected msg: #{inspect msg}"
    after 4000 ->
        raise "Timeout while waiting for file #{filepath}"
    end
  end

  def wait_until_file_exists(filepath) do
    if !File.exists?(filepath) do
      task = Task.async(fn ->
        # Wrapped in a task so that it has its own mailbox.
        Logger.debug "Wait until file #{filepath} is created…"
        {dir, basename} = {Path.dirname(filepath), Path.basename(filepath)}
        expected_output = "CREATE " <> basename <> "\n"
        setup_port(dir)
        if !File.exists?(filepath) do
          wait_until_recvd(expected_output, filepath)
        else
          :ok
        end
      end)
      :ok = Task.await(task)
    else
      :ok
    end
  end

end
