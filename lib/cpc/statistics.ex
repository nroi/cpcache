defmodule Cpc.Statistics do

  # Adapted from https://github.com/msharp/elixir-statistics
  def percentile(list, n, fun \\ fn x -> x end)
  def percentile([], _n, _fun), do: nil
  def percentile(list, 0, fun), do: Enum.min_by(list, fun)
  def percentile(list, 100, fun), do: Enum.max_by(list, fun)
  def percentile(list, n, fun) when is_list(list) and is_number(n) and is_function(fun) do
    s = Enum.sort_by(list, fun)
    r = n/100.0 * (length(list) - 1)
    f = :erlang.trunc(r)
    lower = fun.(Enum.at(s, f))
    upper = fun.(Enum.at(s, f + 1))
    lower + (upper - lower) * (r - f)
  end

  # Returns only those statistics where the measurements are considered accurate.
  def relevant_download_entries()  do
    # Measurements for small files are usually not very accurate. We try to find the minimum
    # content length required to obtain meaningful data.
    # Note that we use some heuristics / best guesses.

    # zu bestimmen ist die minimale Zeit, ab der die download-werte aussagekräftig
    # sind.
    #
    # wähle prozentzahl, zum beispiel 10%
    # wähle die download-Geschwindigkeit in den oberen 20% / den schnellsten 20%.
    #
    # nun sagen wir: die dauer ist dann ausreichend, wenn man mit der geschwindigkeit
    # die oberen 20 % erreichen kann.
    # das es sich um die oberen 10% handelt (nicht die unteren) könnte man einfach mit
    # einem negativen Vorzeichen lösen:
    #
    # Tupel mit der Semantik {Dauer, Geschwindigkeit}
    #     l = [{1, 20}, {2, 22}, {3, 24}, {4, 26}, {5, 28}, {6, 30}, {7, 32}]
    #     min_speed = -Cpc.Statistics.percentile(l, 10, fn {_, x} -> -x end)
    #
    # nun ermitteln wir all die downloads, die diese geschwindigkeit überschreiten:
    #
    # results = Enum.filter(l, fn {_time, speed} -> speed >= min_speed end)
    #
    # # die minimale Zeit, um aussagekräftige download-speed-wert zu erhalten, ist nun:
    # {min_time, _} = Enum.min_by(results, fn {time, _speed} -> time end)
    # # Wobei man eigentlich auch die minimale content length ermitteln könnte.
    #
    # # die relevanten Resultate sind nun:
    # relevant = Enum.filter(l, fn {time, speed} -> time >= min_time end)

    #                    hostname         # content-length #start_time  # diff
    # {DownloadSpeed, "mirror.js-webcoding.de", 1924188, 1492348138739001, 1493847}
    data = [
      {DownloadSpeed, "mirror.js-webcoding.de", 58428, 1491663575961060, 156251},
      {DownloadSpeed, "mirror.js-webcoding.de", 1277720, 1491663576769292, 988226},
      {DownloadSpeed, "mirror.js-webcoding.de", 41140800, 1491663841230273, 33649695},
      {DownloadSpeed, "mirror.js-webcoding.de", 39009944, 1491791978449219, 30234992},
      {DownloadSpeed, "mirror.js-webcoding.de", 266812, 1491792008835450, 266561},
      {DownloadSpeed, "mirror.js-webcoding.de", 253364, 1491792009196543, 208064},
      {DownloadSpeed, "mirror.js-webcoding.de", 1837268, 1491792045308876, 1401207},
      {DownloadSpeed, "mirror.js-webcoding.de", 27400, 1491811223728188, 113213},
      {DownloadSpeed, "mirror.js-webcoding.de", 1313332, 1491811223921757, 994491},
      {DownloadSpeed, "mirror.js-webcoding.de", 9131448, 1491811224960709, 6838345},
      {DownloadSpeed, "mirror.js-webcoding.de", 20932, 1491876220443417, 245500},
      {DownloadSpeed, "mirror.js-webcoding.de", 230912, 1491876220759058, 337158},
      {DownloadSpeed, "mirror.js-webcoding.de", 171308, 1491876245414918, 327690},
      {DownloadSpeed, "mirror.js-webcoding.de", 7508, 1491876245781901, 223056},
      {DownloadSpeed, "mirror.js-webcoding.de", 1151912, 1491876246042104, 1023407},
      {DownloadSpeed, "mirror.js-webcoding.de", 869348, 1491876247117317, 799256},
      {DownloadSpeed, "mirror.js-webcoding.de", 14764, 1491876247963102, 220999},
      {DownloadSpeed, "mirror.js-webcoding.de", 8279808, 1491876248224534, 6343061},
      {DownloadSpeed, "mirror.js-webcoding.de", 15008708, 1491876254611919, 11381584},
      {DownloadSpeed, "mirror.js-webcoding.de", 267360, 1491900296411022, 353981},
      {DownloadSpeed, "mirror.js-webcoding.de", 253976, 1491900296806118, 204520},
      {DownloadSpeed, "mirror.js-webcoding.de", 1171348, 1491940178856786, 1504392},
      {DownloadSpeed, "mirror.js-webcoding.de", 105032, 1491940180439640, 576587},
      {DownloadSpeed, "mirror.js-webcoding.de", 38118520, 1491965211376585, 28937275},
      {DownloadSpeed, "mirror.js-webcoding.de", 19068188, 1491965240348357, 14431069},
      {DownloadSpeed, "mirror.js-webcoding.de", 18764, 1491982112528692, 236058},
      {DownloadSpeed, "mirror.js-webcoding.de", 63704688, 1492015334440700, 50377393},
      {DownloadSpeed, "mirror.js-webcoding.de", 309319812, 1492024731405199, 239349236},
      {DownloadSpeed, "mirror.js-webcoding.de", 7632484, 1492049045083572, 5799185},
      {DownloadSpeed, "mirror.js-webcoding.de", 125872, 1492072559275273, 297579},
      {DownloadSpeed, "mirror.js-webcoding.de", 2846940, 1492072559652240, 2216074},
      {DownloadSpeed, "mirror.js-webcoding.de", 426656, 1492136192242699, 385030},
      {DownloadSpeed, "mirror.js-webcoding.de", 100048, 1492136192678095, 129376},
      {DownloadSpeed, "mirror.js-webcoding.de", 1441540, 1492136209754009, 1090341},
      {DownloadSpeed, "mirror.js-webcoding.de", 10565064, 1492136210884362, 7922352},
      {DownloadSpeed, "mirror.js-webcoding.de", 21332, 1492136218894694, 112888},
      {DownloadSpeed, "mirror.js-webcoding.de", 1357988, 1492136219056072, 1028484},
      {DownloadSpeed, "mirror.js-webcoding.de", 2257840, 1492136220115730, 1694684},
      {DownloadSpeed, "mirror.js-webcoding.de", 232684, 1492136221883248, 219925},
      {DownloadSpeed, "mirror.js-webcoding.de", 818240, 1492136222143791, 715976},
      {DownloadSpeed, "mirror.js-webcoding.de", 91588, 1492136222890123, 134223},
      {DownloadSpeed, "mirror.js-webcoding.de", 1028268, 1492136223086131, 786080},
      {DownloadSpeed, "mirror.js-webcoding.de", 2305900, 1492136223911837, 1935628},
      {DownloadSpeed, "mirror.js-webcoding.de", 5902664, 1492136225894157, 4429206},
      {DownloadSpeed, "mirror.js-webcoding.de", 8553036, 1492136230360221, 6423109},
      {DownloadSpeed, "mirror.js-webcoding.de", 1010032, 1492136263211985, 772431},
      {DownloadSpeed, "mirror.js-webcoding.de", 1383872, 1492174280667988, 1106296},
      {DownloadSpeed, "mirror.js-webcoding.de", 18772, 1492174313262779, 216640},
      {DownloadSpeed, "mirror.js-webcoding.de", 130177780, 1492252914395076, 97465531},
      {DownloadSpeed, "mirror.js-webcoding.de", 1924188, 1492253040336836, 1452775},
      {DownloadSpeed, "mirror.js-webcoding.de", 1627400, 1492311194868759, 1370261},
      {DownloadSpeed, "mirror.js-webcoding.de", 416584, 1492311196327653, 315095},
      {DownloadSpeed, "mirror.js-webcoding.de", 131156, 1492311232194706, 272644},
      {DownloadSpeed, "mirror.js-webcoding.de", 193484, 1492311232559204, 177565},
      {DownloadSpeed, "mirror.js-webcoding.de", 261624, 1492311232770690, 284837},
      {DownloadSpeed, "mirror.js-webcoding.de", 171036, 1492311285595479, 187947},
      {DownloadSpeed, "mirror.js-webcoding.de", 319680, 1492311285840493, 256887},
      {DownloadSpeed, "mirror.js-webcoding.de", 29949148, 1492311286148174, 24008582},
      {DownloadSpeed, "mirror.js-webcoding.de", 173928, 1492347561353393, 225743},
      {DownloadSpeed, "mirror.js-webcoding.de", 253880, 1492347561683642, 286615},
      {DownloadSpeed, "mirror.js-webcoding.de", 360292, 1492347564858741, 340552},
      {DownloadSpeed, "mirror.js-webcoding.de", 510696, 1492347565304554, 538983},
      {DownloadSpeed, "mirror.js-webcoding.de", 2036792, 1492347565893258, 1672034},
      {DownloadSpeed, "mirror.js-webcoding.de", 128660, 1492347567614664, 244117},
      {DownloadSpeed, "mirror.js-webcoding.de", 1215052, 1492347567910515, 1038136},
      {DownloadSpeed, "mirror.js-webcoding.de", 443992, 1492347569007304, 467022},
      {DownloadSpeed, "mirror.js-webcoding.de", 183780, 1492347569548093, 331628},
      {DownloadSpeed, "mirror.js-webcoding.de", 19796, 1492347569949376, 227632},
      {DownloadSpeed, "mirror.js-webcoding.de", 71816, 1492347570252618, 293888},
      {DownloadSpeed, "mirror.js-webcoding.de", 348228, 1492347570616977, 401336},
      {DownloadSpeed, "mirror.js-webcoding.de", 123272, 1492347571095438, 272194},
      {DownloadSpeed, "mirror.js-webcoding.de", 223808, 1492347571450929, 336711},
      {DownloadSpeed, "mirror.js-webcoding.de", 129048, 1492347571865426, 295300},
      {DownloadSpeed, "mirror.js-webcoding.de", 166156, 1492347572274587, 222110},
      {DownloadSpeed, "mirror.js-webcoding.de", 82316, 1492347572548181, 194193},
      {DownloadSpeed, "mirror.js-webcoding.de", 459624, 1492347572791881, 426546},
      {DownloadSpeed, "mirror.js-webcoding.de", 235724, 1492347573272091, 287728},
      {DownloadSpeed, "mirror.js-webcoding.de", 98420, 1492347573617549, 208864},
      {DownloadSpeed, "mirror.js-webcoding.de", 137000, 1492347573876925, 223487},
      {DownloadSpeed, "mirror.js-webcoding.de", 286580, 1492347574149732, 293746},
      {DownloadSpeed, "mirror.js-webcoding.de", 272536, 1492347574484006, 304179},
      {DownloadSpeed, "mirror.js-webcoding.de", 750116, 1492347574898951, 650228},
      {DownloadSpeed, "mirror.js-webcoding.de", 146912, 1492347575599274, 223504},
      {DownloadSpeed, "mirror.js-webcoding.de", 149600, 1492347575873157, 272381},
      {DownloadSpeed, "mirror.js-webcoding.de", 395756, 1492347576215101, 389007},
      {DownloadSpeed, "mirror.js-webcoding.de", 136452, 1492347576653731, 236446},
      {DownloadSpeed, "mirror.js-webcoding.de", 4138244, 1492347576938553, 3358858},
      {DownloadSpeed, "mirror.js-webcoding.de", 122340, 1492347580355171, 210207},
      {DownloadSpeed, "mirror.js-webcoding.de", 216400, 1492347580609980, 277064},
      {DownloadSpeed, "mirror.js-webcoding.de", 393924, 1492347580939669, 384853},
      {DownloadSpeed, "mirror.js-webcoding.de", 2634980, 1492347581374412, 2146937},
      {DownloadSpeed, "mirror.js-webcoding.de", 51780, 1492347583577611, 201068},
      {DownloadSpeed, "mirror.js-webcoding.de", 31510536, 1492347584079842, 24869684},
      {DownloadSpeed, "mirror.js-webcoding.de", 267332, 1492347609828462, 394816},
      {DownloadSpeed, "mirror.js-webcoding.de", 75644, 1492347631052401, 194868}
    ]
    speeds = Enum.map(data, fn {DownloadSpeed, host, content_length, _start, duration} ->
      {host, content_length, content_length / duration, duration}
    end)
    min_speed = -percentile(speeds, 10, fn {_, _, speed, _} -> -speed end)
    fast = Enum.filter(speeds, fn {_, _, speed, _} -> speed >= min_speed end)
    {_, _, _, min_duration} = Enum.min_by(fast, fn {_, _, _, duration} -> duration end)
    relevant = Enum.filter(fast, fn {_, _, _, duration} -> duration >= min_duration end)
    relevant
  end

end
