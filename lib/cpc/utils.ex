defmodule Cpc.Utils do
  def headers_to_lower(headers) do
    Enum.map(headers, fn {key, val} ->
      {key |> to_string |> String.downcase, val |> to_string |> String.downcase}
    end)
  end

  def cache_dir_from_arch(arch) do
    case :ets.lookup(:cpc_config, :cache_directory) do
      [{:cache_directory, cache_directory}] ->
        Path.join(cache_directory, to_string arch)
    end
  end
end
