defmodule Cpc.Utils do
  def headers_to_lower(headers) do
    Enum.map(headers, fn {key, val} ->
      {key |> to_string |> String.downcase, val |> to_string |> String.downcase}
    end)
  end

  def cache_dir_from_distro(distro) when distro == :x86 or distro == :arm do
    case :ets.lookup(:cpc_config, :cache_directory) do
      [{:cache_directory, cache_directory}] ->
        Path.join(cache_directory, to_string distro)
    end
  end

  def wanted_packages_dir(distro, arch) when distro == :x86 or distro == :arm do
    cache_dir = cache_dir_from_distro(distro)
    Path.join([cache_dir, "wanted_packages", arch])
  end
end
