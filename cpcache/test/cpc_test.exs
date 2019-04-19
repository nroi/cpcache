defmodule CpcTest do
  use ExUnit.Case
  @port "7070"
  doctest Cpc

  test "GET a database file via redirection" do
    url = "http://localhost:#{@port}/extra/os/x86_64/extra.db"
    {:ok, 301, headers, _ref} = :hackney.get(url, follow_redirect: true)
    location = headers
    |> Cpc.Utils.headers_to_lower
    |> Map.new
    |> Map.fetch!("location")
    {:ok, 200, _headers, ref} = :hackney.get(location, [])
    {:ok, _body} = :hackney.body(ref)
  end
end
