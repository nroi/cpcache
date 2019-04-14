defmodule IntegrationTests do
  require Logger

  @host "127.0.0.1"

  # Set 'url: "http://repo.helios.click/"' in cpcache.yaml to make use of these test cases.
  # Furthermore, a script called 'clean_test_cache' needs to be in $PATH, it is used to remove all
  # test files (file{1,2,3,4,5,6,7,8,9,10}.xz).
  #
  # current tests:
  # - parallel downloads (see: test_timed_task). The time required to download all files should be
  #   independent of the argument num_tasks (i.e., the number of parallel downloads)
  # - content ranges (see: test_content_ranges)
  #
  # TODO try to integrate these functions into the main project with proper test cases, using
  # ExUnit.

  @timeout 1000 * 60 * 3

  @uris [
    {"http://#{@host}:7070/file1.xz", "16AAB83573EEA2F6BF8BC5EFB19EECEB93B0D0CE"},
    {"http://#{@host}:7070/file2.xz", "05FB85F29792A86410E7218C4B894CFE9C1ACCFC"},
    {"http://#{@host}:7070/file3.xz", "E34098B1A3D10D31D3F33415E840E4F969E48260"},
    {"http://#{@host}:7070/file4.xz", "0D652E81CEEF8CC6D2AF8C0C3ADC62070A667D7A"},
    {"http://#{@host}:7070/file5.xz", "944C03180A35CA8F688B043727B71154C279D233"},
    {"http://#{@host}:7070/file6.xz", "176096033C6E00F10B5EE6D69E88A13D0BB22CC1"},
    {"http://#{@host}:7070/file7.xz", "7FC696227B91BA59911E8648C895E7AB1B57F8A3"},
    {"http://#{@host}:7070/file8.xz", "7957CCA37B6704FB2A169849022455B6E2B31661"},
    {"http://#{@host}:7070/file9.xz", "08A4C9C05E9CDCC156ECD84ECAD0E17C4E7097A4"},
    {"http://#{@host}:7070/file10.xz", "9047BC7BB8F3BFED847181090FA4C8D3B824547E"}
  ]

  @sources_cr [
    # {url, start_at, complete_size, hash}
    {"http://#{@host}:7070/file1.xz", 19663190, 31457280, "BAD3BCAF250339C9FA9B32AA26D9DEA7A6BF211D"},
    {"http://#{@host}:7070/file2.xz", 4763418, 20971520, "9C9FBBAF4FE0803C7ACBCE9B3AD055ADD4E3F4DE"},
    {"http://#{@host}:7070/file3.xz", 577055, 10485760, "55AFB43BBB21325914D4987341C335E660CF85BE"},
    {"http://#{@host}:7070/file4.xz", 23913610, 41943040, "9C8554C45BFF380C497771A2960CF4B87FE168BE"},
    {"http://#{@host}:7070/file5.xz", 948747, 10485760, "876B2331F279B25BC28F5005CF7BCA26ACAD7A25"},
    {"http://#{@host}:7070/file6.xz", 902734, 10485760, "5648F9B1F93E8357715405D3BE1C691207280D98"},
    {"http://#{@host}:7070/file7.xz", 802924, 10485760, "9060B913449B9125452A7A5666D71DB819B96846"},
    {"http://#{@host}:7070/file8.xz", 18419680, 20971520, "9AA8B565B2770B42CEFA42E588248D44C988BF56"},
    {"http://#{@host}:7070/file9.xz", 14756961, 31457280, "AD02F83777E1253A35CF60CC1A7E231E9A31DBA8"},
    {"http://#{@host}:7070/file10.xz", 2881834, 10485760, "6F588FFC428AD75E5E5FE2ECC21852A52A8B7939"}
  ]

  defp recv_acks(num) do
    case num do
      0 -> :ok
      n ->
        receive do
          :ok ->
            Logger.info "ok"
            recv_acks(n - 1)
          :fail ->
            :fail
        end
    end
  end

  def test_timed_task(num_tasks) do
    System.cmd("clean_test_cache", [])
    {microsecs, :ok} = :timer.tc(__MODULE__, :start_tasks, [num_tasks])
    microsecs / 1000000.0
  end

  def start_tasks(num_tasks) do
    pid = self()
    Enum.each(1..num_tasks, fn _ ->
      Task.start(fn -> download(pid) end)
    end)
    :ok = recv_acks(num_tasks * Enum.count(@uris))
    Logger.debug "all done."
  end

  # Given a list of URIs, download them in random order.
  def download(pid, random \\ false) do
    Application.start(:inets)
    :ok = :httpc.set_options(max_pipeline_length: 0)
    transform = case random do
      true ->  &(Enum.take_random(&1, Enum.count(@uris)))
      false -> &(&1)
    end
    @uris
    |> transform.()
    |> Enum.each(fn {uri, sha} ->
        Logger.debug "Start downloading #{uri}"
        {:ok, {{_, 200, 'OK'}, _, body}} = :httpc.request(to_charlist(uri))
        recvd_sha = Base.encode16(:crypto.hash(:sha, body))
        if sha == recvd_sha do
          send pid, :ok
        else
          send pid, :fail
        end
      end)
  end

  def test_content_ranges() do
    Application.start(:inets)
    :ok = :httpc.set_options(max_pipeline_length: 0)
    @sources_cr
    |> Enum.each(fn {url, start, _full_size, sha} ->
         Logger.debug "Start downloading #{url}"
         body = download_from(url, start)
         recvd_sha = Base.encode16(:crypto.hash(:sha, body))
         if sha == recvd_sha do
           Logger.debug "ok"
         else
           Logger.debug "fail"
         end
    end)
  end

  def download_from(url, byte) do
    url = to_charlist(url)
    opts = [{'Range', to_charlist("bytes=#{byte}-")}]
    case :httpc.request(:get, {url, opts}, [timeout: @timeout], body_format: :binary) do
      {:ok, {_, _, content}} -> content
    end
  end

end
