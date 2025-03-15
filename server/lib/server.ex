defmodule HLSPlug do
  use Plug.Router

  plug :add_cors_headers

  plug :match
  plug :dispatch

  options _ do
    send_resp(conn, 204, "")
  end

  get "/playlist.m3u8" do
    IO.puts("..serving dem playlist boiii")
    conn
    |> put_resp_content_type("application/vnd.apple.mpegurl")
    |> send_resp(200, HLSPlaylist.get_playlist())
  end

  get "/:file" do
    file_path = Path.join("data/hls", file)

    if File.exists?(file_path) do
      conn
      |> send_file(200, file_path)
    else
      send_resp(conn, 404, "File Not Found")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp add_cors_headers(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Content-Type")
  end
end

defmodule HLSServer.Playlist do
  use GenServer

  @playlist_path "data/hls/playlist.m3u8"
  @target_duration 10
  @max_segments 5  # Keep only the last 5 segments
  @update_interval :timer.seconds(@target_duration)  # Update every target duration

  ## API

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def add_segment(segment_name) do
    IO.puts("..add_segment #{segment_name}")
    GenServer.cast(__MODULE__, {:add_segment, segment_name})
  end

  def get_playlist, do: File.read!(@playlist_path)

  ## GenServer Callbacks

  def init(_) do
    segments = load_existing_segments()
    IO.puts segments
    # schedule_update()
    {:ok, segments}
  end

  def handle_cast({:add_segment, segment_name}, segments) do
    new_segments = (segments ++ [segment_name]) |> Enum.take(-@max_segments)
    write_playlist(new_segments)
    {:noreply, new_segments}
  end

  def handle_info(:update, segments) do
    write_playlist(segments)  # Refresh playlist file
    schedule_update()
    {:noreply, segments}
  end

  ## Private Functions

  defp schedule_update() do
    IO.puts("schedule update")
    Process.send_after(self(), :update, @update_interval)
  end

  defp write_playlist(segments) do
    IO.puts("..writing playlist")
    content = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:#{@target_duration}",
      "#EXT-X-MEDIA-SEQUENCE:#{max(0, length(segments) - @max_segments)}"
    ] ++ Enum.map(segments, fn seg -> "#EXTINF:#{@target_duration}.000,\n#{seg}" end)

    File.write!(@playlist_path, Enum.join(content, "\n") <> "\n")
  end

  defp load_existing_segments() do
    case File.read(@playlist_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.filter(&String.ends_with?(&1, ".ts"))  # Extract segment filenames
      _ ->
        []
    end
  end
end


defmodule HLSServer.Downloader do
  use GenServer

  @video_dir "data"
  @rss_url "https://archive.org/services/collection-rss.php?collection=ucberkeley-webcast"
  @saved_urls_path "ucberkeley-webcast.json"

  def start_link() do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init() do
    HTTPoison.start()
    saved_urls = get_saved_urls(@saved_urls_path)
    saved_urls_hash = hash(saved_urls)

    {:ok, %{
      rss_url: @rss_url,
      saved_urls_path: @saved_urls_path,
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

    with {:ok, rss_string} <- get_rss_string(state.rss_url),
         {:ok, map_of_rss} <- FastRSS.parse_rss(rss_string) do
      items = map_of_rss["items"]
      urls =
        items
        |> Enum.map(& &1["extensions"]["media"]["content"])
        |> List.flatten()
        |> Enum.map(& &1["attrs"]["url"])

      urls_hash = hash(urls)

      if state.saved_urls_hash != urls_hash do
        File.write!(state.saved_urls_path, Poison.encode!(urls))
        {:ok, urls}
      else
        {:ok, state.saved_urls}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare_stream(urls) do
    [head | _tail] = urls
    download!(head) |> convert_to_hls()
  end

  def setup_stream() do
    case fetch_latest_videos() do
      {:ok, urls} -> prepare_stream(urls)
      {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
    end
  end

  defp download!(url, filepath \\ "buffer.mp4") do
    File.rm(filepath)
    {_, exit_status} = System.cmd("aria2c", ["-x", "16", "-s", "16", "-o", filepath, url], into: IO.stream(:stdio, :line))
    if exit_status == 0, do: filepath, else: raise "Download failed with exit status #{exit_status}"
  end

  def convert_to_hls(input_path, output_dir \\ @video_dir) do
    File.mkdir_p!(output_dir)
    output_m3u8 = Path.join(output_dir, "playlist.m3u8")

    ffmpeg_command = [
      "-i", input_path,
      "-codec", "copy",
      "-start_number", "0",
      "-hls_time", "10",
      "-hls_list_size", "0",
      "-hls_segment_filename", Path.join(output_dir, "segment_%03d.ts"),
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

  defp hash(list), do: :crypto.hash(:sha256, Enum.join(list, ",")) |> Base.encode16()
end


defmodule HLSServer.Application do
  use Application

  def start(_type, _args) do
    start()
  end
  def start() do
    port = 4000
    IO.puts("Server listening on port #{port}")

    children = [
      HLSServer.Playlist,
      {Plug.Cowboy, scheme: :http, plug: HLSPlug, options: [port: port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
