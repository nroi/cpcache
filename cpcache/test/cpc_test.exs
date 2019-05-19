defmodule CpcTest do
  use ExUnit.Case
  require Logger
  @port "7070"
  doctest Cpc

  def get_db_file_body(repository) do
    url = "http://localhost:#{@port}/#{repository}/os/x86_64/#{repository}.db"
    {:ok, 301, headers, _ref} = :hackney.get(url, follow_redirect: true)

    location =
      headers
      |> Cpc.Utils.headers_to_lower()
      |> Map.new()
      |> Map.fetch!("location")

    {:ok, 200, _headers, ref} = :hackney.get(location, [])
    {:ok, body} = :hackney.body(ref)
    body
  end

  @doc """
  Returns a list containing all files and their contents from the compressed tar archive.
  """
  def extract_tar_from_binary(binary) do
    with {:ok, files} <- :erl_tar.extract({:binary, binary}, [:memory, :compressed]) do
      files
      |> Enum.map(fn {filename, content} -> {to_string(filename), content} end)
    end
  end

  def sha256_digest(binary), do: Base.encode16(:crypto.hash(:sha256, binary))

  defp url_from_filename(repo, filename),
    do: "http://localhost:#{@port}/#{repo}/os/x86_64/#{filename}"

  def get_files_sorted_by_size(repo) do
    get_db_file_body(repo)
    |> extract_tar_from_binary
    |> Enum.reduce([], fn {file, content}, acc ->
      case Cpc.AlpmUtils.parse_db(content) do
        {:ok, result} -> [{file, repo, result} | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.sort_by(fn {_file, _repo, content} ->
      String.to_integer(content["CSIZE"])
    end)
  end

  def get_files_sorted_by_size() do
    ["core", "extra", "community"]
    |> Enum.map(&get_files_sorted_by_size/1)
    |> Enum.concat()
  end

  def download_and_digest(url) do
    {:ok, 200, _headers, ref} = :hackney.get(url)
    {:ok, body} = :hackney.body(ref)
    sha256_digest(body)
  end

  def download_and_abort(repo, filename, abort_after_millisecs) do
    url = url_from_filename(repo, filename)

    task =
      Task.async(fn ->
        {:ok, 200, _headers, ref} = :hackney.get(url)
        {:ok, _body} = :hackney.body(ref)
      end)

    :timer.sleep(abort_after_millisecs)
    Task.shutdown(task, :brutal_kill)
  end

  def test_file(repo, filename, digest_should) do
    url = url_from_filename(repo, filename)
    # Repeat a few times to make sure we also test the cache.
    for _ <- 1..5 do
      digest_is = download_and_digest(url)
      assert digest_is == digest_should
    end
  end

  test "GET a database file via redirection" do
    get_db_file_body("core")
    get_db_file_body("extra")
  end

  test "GET the smallest file" do
    repo = "core"
    files_sorted_by_size = get_files_sorted_by_size(repo)
    [{_filename, ^repo, filemap} | _] = files_sorted_by_size
    filename = filemap["FILENAME"]
    digest_should = String.upcase(filemap["SHA256SUM"])
    test_file(repo, filename, digest_should)
  end

  test "GET the 20 smallest files" do
    repo = "core"
    # Usually, we use the download limit during testing. However, this would skew our results,
    # so we disable them temporarily.
    prev_value = Application.get_env(:cpcache, :throttle_downloads)
    Application.put_env(:cpcache, :throttle_downloads, false)
    # Skip the first file: It is already in cache, and we want to test the download behavior.
    [_already_downloaded | files_sorted_by_size] = get_files_sorted_by_size(repo)

    latencies =
      for {_filename, ^repo, filemap} <- Enum.take(files_sorted_by_size, 20) do
        filename = filemap["FILENAME"]
        url = url_from_filename(repo, filename)
        digest_should = String.upcase(filemap["SHA256SUM"])
        {microsecs, digest_is} = :timer.tc(__MODULE__, :download_and_digest, [url])
        Logger.debug("Time required to download #{filename}: #{microsecs / 1000} ms")
        assert digest_is == digest_should
        microsecs
      end

    sorted_latencies = Enum.sort(latencies)
    Logger.error("Average latency: #{Enum.sum(sorted_latencies) / Enum.count(sorted_latencies)}")
    Logger.error("Median latency: #{Enum.at(sorted_latencies, 10)}")
    Logger.error("All latencies: #{inspect(latencies)}")
    Application.put_env(:cpcache, :throttle_downloads, prev_value)
  end

  test "a client aborting the download does not cause errors for other clients fetching the same file" do
    files_sorted_by_size = get_files_sorted_by_size()

    # with the speed throttled to 100KiB/s, a file with a size somewhere around 300KiB should be sufficient.
    range = trunc(307_200 * 0.8)..trunc(307_200 * 1.2)

    {_filename, repo, filemap} =
      Enum.find(files_sorted_by_size, fn
        {_filename, _repo, filemap} -> String.to_integer(filemap["CSIZE"]) in range
      end)

    filename = filemap["FILENAME"]
    digest_should = String.upcase(filemap["SHA256SUM"])
    url = url_from_filename(repo, filename)

    task1 =
      Task.async(fn ->
        {:ok, 200, _headers, ref} = :hackney.get(url)
        {:ok, _body} = :hackney.body(ref)
      end)

    :timer.sleep(300)

    task2 =
      Task.async(fn ->
        {:ok, 200, _headers, ref} = :hackney.get(url)
        {:ok, body} = :hackney.body(ref)
        body
      end)

    :timer.sleep(300)
    Task.shutdown(task1, :brutal_kill)

    # task1 has been killed, but this must not interfere with task2! cpcache needs to be able to recognize
    # that there is still another ongoing download for the same file and therefore it must not close the
    # connection to the remote mirror.
    body = Task.await(task2)
    digest_is = sha256_digest(body)
    assert digest_is == digest_should
  end
end
