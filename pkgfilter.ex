defmodule PkgFilter do
  require Logger

  def split_filename(filename) do
    components = filename |> String.split("-") |> Enum.reverse
    [extension | [pkgrel | [pkgver | rest]]] = components
    version = "#{pkgver}-#{pkgrel}"
    pkgname = rest |> Enum.reverse |> Enum.join("-")
    {pkgname, version, extension}
  end

  def pkgname(filename) do
    {pkgname, _, _} = split_filename(filename)
    pkgname
  end


  # Given a filename, return all files in this directory which may be deleted.
  def deletion_candidates(filename, keep) do
    pkgname = pkgname(filename)
    filenames = Path.dirname(filename)
                |> File.ls!
                |> Enum.filter(fn filename ->
                  pkgname(filename) == pkgname
                end)
                # port = Port.open({:spawn_executable, "/usr/bin/pacsort"}, [{:args, ["--files"]}])
    port = Port.open({:spawn_executable, "/usr/bin/cat"}, [:binary])
    Enum.each(filenames, fn filename ->
      Port.command port, filename <> "\n"
    end)
    receive do
      m -> IO.inspect m
    end
    IO.inspect(Port.info(port))
    Port.close(port)
    # filenames
  end

  # PkgFilter.deletion_candidates("/tmp/pacman_cache/flex-2.6.1-1-x86_64.pkg.tar.xz", 3

  def sort_test() do
    filenames = File.read!("packages")
    sorted = sort_by_version(String.split(filenames))
    sorted_new = Enum.map(sorted, fn filename ->
      IO.inspect filename
      {_, version, _} = split_filename(filename)
      IO.inspect version
      version
    end)
    File.write!("/tmp/sorted1", Enum.join(sorted_new, "\n"))
  end

  def sort_by_version(filenames) do
    filenames
    |> Enum.sort(fn (filename1, filename2) ->
      {_, version1, _} = split_filename(filename1)
      {_, version2, _} = split_filename(filename2)
      rpmvercmp_ref(version1, version2)
    end)
  end

  def rpmvercmp_ref(s1, s2) do
    case System.cmd("vercmp", [s1, s2]) do
      {"-1\n", 0} -> true
      {"0\n", 0} -> false
      {"1\n", 0}  -> false
    end
  end

  def to_number(s) do
    case {Integer.parse(s), Float.parse(s)} do
      {{int, ""}, _} -> {:ok, {:integer, int}}
      {_, {float, ""}} -> {:ok, {:float, float}}
      _ -> {:error, :no_number}
    end
  end

  def rpmvercmp(s1, s2) do
    result = rpmvercmp_(s1, s2)
    ref_result = rpmvercmp_ref(s1, s2)
    Logger.debug "#{result} = #{ref_result}"
    ^result = ref_result
    result
  end

  def rpmvercmp_(s1, s2) do
    case {to_number(s1), to_number(s2)} do
      {{:ok, {:integer, n1}}, {:ok, {:integer, n2}}} ->
        n1 < n2
      {{:ok, {:float, n1}}, {:ok, {:float, n2}}} ->
        n1 < n2
      {{:ok, {:integer, _n1}}, {:ok, {:float, _n2}}} ->
        true
      {{:ok, {:float, _n1}}, {:ok, {:integer, _n2}}} ->
        false
      {{:ok, {_, _n1}}, {:error, :no_number}} ->
        false
      {{:error, :no_number}, {:ok, _}} ->
        true
      {{:error, :no_number}, {:error, :no_number}}
        s1 < s2
    end
  end
end
