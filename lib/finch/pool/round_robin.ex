defmodule Finch.Pool.RoundRobin do
  @moduledoc """
  Cycle through the pools one by one, in a consistent order.
  """
  @behaviour Finch.Pool.Strategy

  @impl true
  def registry_value(%{count: count}) do
    atomics = :atomics.new(1, [])
    %{strategy: __MODULE__, count: count, atomics: atomics}
  end

  @impl true
  def choose_pool([{_, registry_value} | _] = pids) do
    %{atomics: atomics, count: count} = registry_value
    index = :atomics.add_get(atomics, 1, 1)
    {pid, _} = Enum.at(pids, rem(index, count))

    pid
  end
end
