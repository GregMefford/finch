defmodule Finch.Pool do
  @moduledoc false
  @behaviour NimblePool

  alias Finch.Conn

  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link({shp, registry_name, pool_size}) do
    opts = [worker: {__MODULE__, {registry_name, shp}}, pool_size: pool_size]
    NimblePool.start_link(opts)
  end

  def request(pool, req, opts) do
    pool_timeout = Keyword.get(opts, :pool_timeout, 5_000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)

    NimblePool.checkout!(
      pool,
      :checkout,
      fn {conn, pool} ->
        conn = Conn.connect(conn)

        with {:ok, conn, response} <- Conn.request(conn, req, receive_timeout),
             {:ok, conn} <- Conn.transfer(conn, pool) do
          {{:ok, response}, conn}
        else
          {:error, conn, error} ->
            {{:error, error}, conn}

          {:error, error} ->
            {{:error, error}, conn}
        end
      end,
      pool_timeout
    )
  end

  @impl NimblePool
  def init_pool({_, {registry, shp}, _}) do
    {:ok, _} = Registry.register(registry, shp, [])
    :ok
  end

  @impl NimblePool
  def init({_, {scheme, host, port}}) do
    parent = self()

    async = fn ->
      Conn.connect(Conn.new(scheme, host, port, [], parent))
    end

    {:async, async}
  end

  @impl NimblePool
  # Transfer the conn to the caller.
  # If we lost the connection, then we remove it to try again.
  def handle_checkout(:checkout, {pid, _}, conn) do
    case Conn.transfer(conn, pid) do
      {:ok, conn} -> {:ok, {conn, self()}, conn}
      error ->
        Logger.error(fn -> "failed to checkout connection: #{inspect error}" end)
        {:remove, :closed}
    end
  end

  @impl NimblePool
  def handle_checkin(conn, _from, _old_conn) do
    case Conn.set_mode(conn, :active) do
      {:ok, conn} -> {:ok, conn}
      {:error, _} ->
        Logger.error(fn -> "Removing connection after checkin" end)
        {:remove, :closed}
    end
  end

  @impl NimblePool
  def handle_info(message, conn) do
    case Conn.stream(conn, message) do
      {:ok, _, _} -> {:ok, conn}
      {:error, _, error, _} ->
        Logger.error("Error handling stream: #{inspect error}")
        {:remove, :closed}
      {:error, error} ->
        Logger.error("Error handling stream: #{inspect error}")
        {:remove, :closed}
      :unknown -> {:ok, conn}
    end
  end

  @impl NimblePool
  # On terminate, effectively close it.
  # This will succeed even if it was already closed or if we don't own it.
  def terminate(_reason, conn) do
    Conn.close(conn)
    :ok
  end
end
