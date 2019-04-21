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

  test "GET a database file via redirection" do
    get_db_file_body("core")
    get_db_file_body("extra")
  end

  test "GET the smallest file" do
    repo = "core"

    sorted_files =
      get_db_file_body(repo)
      |> extract_tar_from_binary
      |> Enum.map(fn {file, content} ->
        {file, Cpc.AlpmUtils.parse_db(content)}
      end)
      |> Enum.sort_by(fn {_file, content} ->
        content["CSIZE"]
      end)

    [{_filename, filemap} | _] = sorted_files
    filename = filemap["FILENAME"]
    digest_should = String.upcase(filemap["SHA256SUM"])
    url = "http://localhost:7070/#{repo}/os/x86_64/#{filename}"
    {:ok, 200, headers, ref} = :hackney.get(url, follow_redirect: true)
    {:ok, body} = :hackney.body(ref)
    digest_is = sha256_digest(body)
    assert digest_is == digest_should
  end

  test "nothing at all" do
  end
end
