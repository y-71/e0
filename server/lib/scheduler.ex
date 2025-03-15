defmodule HLSServer.Scheduler do
  use GenServer

  @video_dir "data"
  @rss_url "https://archive.org/services/collection-rss.php?collection=computerchronicles"
  @saved_urls_path (@rss_url |> String.split("collection=") |> List.last()) <> ".json"

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    HTTPoison.start()
    saved_urls = get_saved_urls(@saved_urls_path)
    saved_urls_hash = hash(Enum.join(saved_urls, ","))

    {:ok, %{
      saved_urls: saved_urls,
      saved_urls_hash: saved_urls_hash
    }}
  end

  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def get_rss_string(url) do
    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, body}
      {:ok, %HTTPoison.Response{status_code: 404}} -> {:error, "404 Not Found"}
      {:error, %HTTPoison.Error{reason: reason}} -> {:error, reason}
    end
  end

  def fetch_latest_videos do
    state = GenServer.call(__MODULE__, :get_state)

    with {:ok, rss_string} <- get_rss_string(@rss_url),
         {:ok, map_of_rss} <- FastRSS.parse_rss(rss_string) do
      items = map_of_rss["items"]
      urls =
        items
        |> Enum.map(& &1["extensions"]["media"]["content"])
        |> List.flatten()
        |> Enum.map(& &1["attrs"]["url"])
        |> Enum.reject(&is_nil/1)  # Removes nil values

      urls_hash = hash(Enum.join(urls, ","))

      if state.saved_urls_hash != urls_hash do
        File.write!(@saved_urls_path, Poison.encode!(urls))
        {:ok, urls}
      else
        {:ok, state.saved_urls}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare_stream(urls) do
    [head | tail] = urls
    download!(head) |> convert_to_hls()
    prepare_stream(tail)
  end

  def setup_stream() do
    case fetch_latest_videos() do
      {:ok, urls} -> prepare_stream(urls)
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp download!(url) do
    download!(url, @video_dir <> "/" <> hash(url))
  end

  defp download!(url, filepath) do
    File.rm(filepath)
    {_, exit_status} = System.cmd("aria2c", ["-x", "16", "-s", "16", "-o", filepath, url], into: IO.stream(:stdio, :line))
    if exit_status == 0, do: filepath, else: raise "Download failed with exit status #{exit_status}"
  end

  def convert_to_hls(input_path, output_dir \\ @video_dir <> "/hls") do
    File.mkdir_p!(output_dir)
    stream_name = hash(input_path)
    output_m3u8 = Path.join(output_dir, stream_name <> ".m3u8")

    ffmpeg_command = [
      "-i", input_path,
      "-codec", "copy",
      "-start_number", "0",
      "-hls_time", HLSServer.Stream.target_duration(),
      "-hls_list_size", "0",
      "-hls_segment_filename", Path.join(output_dir, stream_name<> "_segment_%03d.ts"),
      output_m3u8
    ]

    case System.cmd("ffmpeg", ffmpeg_command, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, error}
    end
  end

  def get_saved_urls(path) do
    case File.read(path) do
      {:ok, urls} -> Poison.decode!(urls)
      {:error, _} -> []
    end
  end

  defp hash(object), do: :crypto.hash(:sha256, object) |> Base.encode16()
end
