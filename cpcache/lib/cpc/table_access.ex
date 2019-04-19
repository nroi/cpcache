defmodule Cpc.TableAccess do
  require Logger

  def filename(table) do
    [{:cache_directory, cache_directory}] = :ets.lookup(:cpc_config, :cache_directory)
    to_charlist(Path.join([cache_directory, "state", table]))
  end

  def create_table(table) do
    fname = filename(table)

    case :dets.open_file(fname, type: :set, repair: false) do
      {:ok, _} ->
        :ok

      {:error, {:needs_repair, ^fname}} ->
        # Attempting to repair a file often fails, so we just delete the old one and a new one
        # instead.
        File.rm!(fname)
        _ = Logger.warn("File #{fname} not properly closed, will be deleted and newly created.")
        {:ok, _} = :dets.open_file(fname, type: :set, repair: false)
    end
  end

  def get(table, key) do
    case :dets.lookup(filename(table), key) do
      [{^key, value}] ->
        {:ok, value}

      [] ->
        {:error, :not_found}
    end
  end

  def add(table, key, value) do
    :dets.insert_new(filename(table), {key, value})
  end
end
