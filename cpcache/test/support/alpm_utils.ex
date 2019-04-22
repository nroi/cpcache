defmodule Cpc.AlpmUtils do
  require Logger

  def parse_db(db) do
    # try-rescue is used because experience has shown that the db files sometimes contain borked description files.
    try do
      result =
        db
        |> String.replace_trailing("\n", "")
        |> String.split("\n\n")
        |> Enum.reduce([], fn
          "%" <> rest, acc ->
            [header, value] = String.split(rest, "\n", parts: 2)
            [{String.replace_suffix(header, "%", ""), value} | acc]
        end)
        |> Map.new()

      {:ok, result}
    rescue
      e -> {:error, e}
    end
  end
end
