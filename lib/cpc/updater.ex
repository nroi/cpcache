defmodule Cpc.Updater do
  require Logger

  def package_names do
    url = 'http://archlinux.polymorf.fr/multilib/os/x86_64/multilib.db'
    {:ok, {{_, 200, 'OK'}, _, data}} = :httpc.request(:get, {url, []}, [], [])
    unzipped = :zlib.gunzip(data)
    {:ok, filenames} = :erl_tar.table({:binary, unzipped})
    filenames
    |> Enum.map(&to_string/1)
    |> Enum.filter_map(&String.ends_with?(&1, "/"), &String.replace_suffix(&1, "/", ""))
  end

  def packages_with_versions do
    package_names()
    |> Enum.map(&Regex.run(~r/(.*)(-.*-.*)$/, &1, capture: :all_but_first))
    |> Enum.map(fn [pkgname, "-" <> version] -> {pkgname, version} end)
  end
end
