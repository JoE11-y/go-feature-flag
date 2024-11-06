defmodule ElixirProvider.HttpClient do
  @moduledoc """
  Handles HTTP requests to the GO Feature Flag API.
  """

  use GenServer

  # Define a struct to store HTTP connection, endpoint, and other configuration details
  defstruct [:conn, :endpoint, :headers]

  @type t :: %__MODULE__{
          conn: Mint.HTTP.t() | nil,
          endpoint: String.t(),
          headers: list()
        }

  @spec start_link() :: GenServer.on_start()
  def start_link() do
    GenServer.start_link(__MODULE__, :ok, name:  __MODULE__)
  end

  def stop() do
    GenServer.stop(__MODULE__)
  end

  @impl true
  def init([]) do
    {:ok, %__MODULE__{}}
  end

  @spec start_http_connection(any()) ::
          {:error,
           %{
             :__exception__ => true,
             :__struct__ => Mint.HTTPError | Mint.TransportError,
             :reason => any(),
             optional(:module) => any()
           }}
          | {:ok, ElixirProvider.HttpClient.t()}
  def start_http_connection(options) do
    uri = URI.parse(options.endpoint)
    scheme = if uri.scheme == "https", do: :https, else: :http

    case Mint.HTTP.connect(scheme, uri.host, uri.port) do
      {:ok, conn} ->
        # Create the struct with the connection, endpoint, and default headers
        config = %__MODULE__{
          conn: conn,
          endpoint: options.endpoint,
          headers: [{"content-type", "application/json"}]
        }

        {:ok, config}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec post(t(), String.t(), map()) :: {:ok, map()} | {:error, any()}
  def post(%__MODULE__{conn: conn, endpoint: endpoint, headers: headers}, path, data) do
    # Full URL path
    url = URI.merge(endpoint, path) |> URI.to_string()
    body = Jason.encode!(data)

    # Make the POST request using the existing connection
    with {:ok, conn, request_ref} <- Mint.HTTP.request(conn, "POST", url, headers, body),
         {:ok, response} <- read_response(conn, request_ref) do
      Jason.decode(response)
    else
      {:error, _conn, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_response(conn, request_ref) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, _conn, responses} ->
            Enum.reduce_while(responses, {:ok, ""}, fn
              {:status, ^request_ref, status}, _acc ->
                if status == 200, do: {:cont, {:ok, ""}}, else: {:halt, {:error, :bad_status}}

              {:headers, ^request_ref, _headers}, acc ->
                {:cont, acc}

              {:data, ^request_ref, data}, {:ok, acc} ->
                {:cont, {:ok, acc <> data}}

              {:done, ^request_ref}, {:ok, acc} ->
                {:halt, {:ok, acc}}

              _other, acc ->
                {:cont, acc}
            end)

          :unknown ->
            {:error, :unknown_response}
        end
    after
      5_000 -> {:error, :timeout}
    end
  end
end
