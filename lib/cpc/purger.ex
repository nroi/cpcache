defmodule Cpc.Purger do
  use GenServer
  require Logger
  @purge_wait 10 * 1000 * 60

  def start_link(cache_directory, keep, name) do
    GenServer.start_link(__MODULE__, {cache_directory, keep, nil}, name: name)
  end

  def handle_cast(:purge, {cache_directory, keep, _id}) do
    new_id = :erlang.unique_integer()
    :timer.send_after(@purge_wait, {:purge_id, new_id})
    {:noreply, {cache_directory, keep, new_id}}
  end

  def handle_info({:purge_id, id}, state = {cache_directory, keep, state_id}) do
    if id == state_id do
      purge(cache_directory, keep)
      {:noreply, {cache_directory, keep, nil}}
    else
      Logger.debug "Not the most recent purge request, ignore."
      {:noreply, state}
    end
  end

  def contains_package(directory) do
    File.ls!(directory) |> Enum.any?(&String.contains?(&1, ".pkg.tar"))
  end

  def package_directories(parent) do
    File.ls!(parent)
    |> Enum.map(&Path.join(parent, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn path ->
      if contains_package(path) do
        [path | package_directories(path)]
      else
        package_directories(path)
      end
    end)
  end

  # purges all older packages for all repositories (core, extra, community, …)
  def purge(cache_directory, keep) do
    commands = Enum.map(package_directories(cache_directory), fn path ->
      {"/usr/bin/paccache", ["-r", "-c", path, "-k", to_string(keep), "--nocolor"]}
    end)
    Enum.each(commands, fn {command, args} ->
      {output, 0} = System.cmd(command, args)
      Logger.info "paccache: #{output}"
    end)
  end



end
