defmodule Cpc.Purger do
  use GenServer
  require Logger
  @purge_wait 1000 * 3600

  def start_link(cache_directory, keep, name) do
    GenServer.start_link(__MODULE__, {cache_directory, keep}, name: name)
  end

  def init(state) do
    {:ok, _} = :timer.send_after(@purge_wait, :purge_all)
    {:ok, state}
  end

  def handle_info(:purge_all, {cache_directory, keep}) do
    filenames = Path.wildcard("#{cache_directory}/**/*.tar.xz")
    pkgname2filenames = Enum.group_by(filenames, &pkgname/1)
    Enum.each(pkgname2filenames, fn {pkgname, filenames} ->
      dirname2filenames = Enum.group_by(filenames, &Path.dirname/1)
      Enum.each(dirname2filenames, fn {dirname, _filename} ->
        purge(pkgname, dirname, keep)
      end)
    end)
    {:ok, _} = :timer.send_after(@purge_wait, :purge_all)
    {:noreply, {cache_directory, keep}}
  end

  def handle_cast({:purge, filename}, {cache_directory, keep}) do
    dirname = Path.dirname(filename)
    purge(pkgname(filename), dirname, keep)
    {:noreply, {cache_directory, keep}}
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
  def purge(pkgname, dirname, keep) do
    deletion_candidates =
      File.ls!(dirname)
      |> Enum.map(&Path.join(dirname, &1))
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(fn filename -> String.ends_with?(filename, ".tar.xz") end)
      |> Enum.map(fn filename ->
           case split_filename(filename) do
             {ppkgname, _, _} -> {filename, ppkgname}
           end
         end)
      |> Enum.filter(fn {_, ppkgname} -> ppkgname == pkgname end)
    filenames = Enum.map(deletion_candidates, fn {filename, _} -> filename end)
    to_delete = prune_packages(filenames, keep)
    Enum.each(to_delete, fn filename ->
      _ = Logger.debug "Delete file: #{filename}"
      :ok = File.rm(filename)
    end)
  end

  def split_filename(filename) do
    components = filename |> String.split("-") |> Enum.reverse
    [extension | [pkgrel | [pkgver | rest]]] = components
    version = "#{pkgver}-#{pkgrel}"
    pkgname = rest |> Enum.reverse |> Enum.join("-") |> Path.basename
    {pkgname, version, extension}
  end

  # Returns the package names sorted in descending order, i.e., most recent packages first.
  def pacsort(package_names) do
    # Creating a temporary file only to run pacsort seems a bit involved, but the alternatives
    # aren't any better:
    #    - Run a port, send the input via stdin, receive the stdout via message passing.
    #    - Use the vercmp command in order to sort the package_names, i.e., call
    #      vercmp for each comparison. This is very slow with a large number of package names.
    #    - Create a NIF to call the C function alpm_pkg_vercmp. NIFs introduce additional
    #      complexity (Makefile and additional C code are required).
    #    - Implement it entirely in elixir. Unfortunately, its difficult to just *understand*
    #      the version comparison and then implement it without looking at the C code, since there
    #      are lots of rules that don't follow any particular logic. Translating C to elixir is
    #      also difficult, since the two languages are entirely different.
    filename = case System.cmd("/usr/bin/mktemp", []) do
      {output, 0} -> String.trim_trailing(output, "\n")
    end
    file = File.open!(filename, [:write])
    Enum.each(package_names, fn pkgname ->
        IO.write(file, pkgname <> "\n")
    end)
    sorted = case System.cmd("/usr/bin/pacsort", ["--reverse", "-f", filename]) do
               {output, 0} -> String.split(output)
             end
    :ok = File.close(file)
    :ok = File.rm(filename)
    sorted
  end

  # Returns a list of packages that are not among the `keep` most recent packages.
  def prune_packages(filenames, keep \\ 3) do
    most_recent = Enum.take(pacsort(filenames), keep)
    Enum.filter(filenames, &(!Enum.member?(most_recent, &1)))
  end

  def pkgname(filename) do
    {pkgname, _, _} = split_filename(filename)
    pkgname
  end
end
