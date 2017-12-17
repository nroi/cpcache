defmodule Cpc.Utils do
  def headers_to_lower(headers) do
    Enum.map(headers, fn {key, val} ->
      {key |> to_string |> String.downcase, val |> to_string |> String.downcase}
    end)
  end

  # Returns the directory where the "wanted packages" are stored on the server
  # (i.e., the packages that a given client wants to have downloaded in advance).
  def wanted_packages_dir() do
    [{:cache_directory, cache_directory}] = :ets.lookup(:cpc_config, :cache_directory)
    Path.join([cache_directory, "wanted_packages"])
  end
end
