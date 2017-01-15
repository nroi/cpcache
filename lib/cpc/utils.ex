defmodule Cpc.Utils do
  def headers_to_lower(headers) do
    Enum.map(headers, fn {key, val} ->
      {key |> to_string |> String.downcase, val |> to_string |> String.downcase}
    end)
  end
end
