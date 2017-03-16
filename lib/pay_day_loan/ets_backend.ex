defmodule PayDayLoan.EtsBackend do
  @moduledoc """
  ETS-based backend capable of handling raw values, pids, or callbacks.
  """

  @behaviour PayDayLoan.Backend

  @doc """
  Setup callback, creates the underlying ETS table
  """
  @spec setup(PayDayLoan.t) :: :ok
  def setup(%PayDayLoan{backend_id: backend_id}) do
    _ = :ets.new(
      backend_id,
      [:public, :named_table, {:read_concurrency, true}]
    )
    :ok
  end

  @doc """
  Perform Enum.reduce on the ETS table
  """
  @spec reduce(PayDayLoan.t, term, (({PayDayLoan.key, pid}, term) -> term)) :: term
  def reduce(pdl = %PayDayLoan{backend_id: backend_id}, acc0, reducer)
  when is_function(reducer, 2) do
    :ets.foldl(
      fn({k, v}, acc) ->
        case resolve_value(v, k, pdl) do
          {:ok, resolved_v} -> reducer.({k, resolved_v}, acc)
          {:error, :not_found} -> acc
        end
      end,
      acc0,
      backend_id
    )
  end

  @doc """
  Returns the number of cached keys
  """
  @spec size(PayDayLoan.t) :: non_neg_integer
  def size(%PayDayLoan{backend_id: backend_id}) do
    :ets.info(backend_id, :size)
  end

  @doc """
  Returns a list of all cached keys
  """
  @spec keys(PayDayLoan.t) :: [PayDayLoan.key]
  def keys(pdl = %PayDayLoan{}) do
    reduce(pdl, [], fn({k, _pid}, acc) -> [k | acc] end)
  end

  @doc """
  Returns a list of all cached values
  """
  @spec values(PayDayLoan.t) :: [term]
  def values(pdl = %PayDayLoan{}) do
    reduce(pdl, [], fn({_k, v}, acc) -> [v | acc] end)
  end

  @doc """
  Get the value corresponding to the given key

  If the value is a process that is not alive, deletes the entry and returns
  `{:error, :not_found}`.
  """
  @spec get(PayDayLoan.t, PayDayLoan.key) :: {:ok, term} | {:error, :not_found}
  def get(pdl = %PayDayLoan{}, key) do
    case lookup(pdl, key) do
      {:ok, pre_resolve_value} -> resolve_value(pre_resolve_value, key, pdl)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Add a value to the cache and monitor it if it is a pid.
  """
  @spec put(PayDayLoan.t, PayDayLoan.key, term) :: :ok
  def put(pdl = %PayDayLoan{backend_id: backend_id}, key, value) do
    :ets.insert(backend_id, {key, value})
    if is_pid(value) do
      GenServer.cast(pdl.cache_monitor, {:monitor, value})
    end
    :ok
  end

  @doc """
  Remove a value from cache
  """
  @spec delete_value(PayDayLoan.t, term) :: :ok
  def delete_value(%PayDayLoan{backend_id: backend_id}, value) do
    true = :ets.match_delete(backend_id, {:'_', value})
    :ok
  end

  @doc """
  Remove a key from cache
  """
  @spec delete(PayDayLoan.t, PayDayLoan.key) :: :ok
  def delete(%PayDayLoan{backend_id: backend_id}, key) do
    true = :ets.delete(backend_id, key)
    :ok
  end

  defp lookup(%PayDayLoan{backend_id: backend_id}, key) do
    case :ets.lookup(backend_id, key) do
      [{_key, pid}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp resolve_value(cb, key, _pdl) when is_function(cb, 1) do
    cb.(key)
  end
  defp resolve_value(pid, _key, pdl) when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, pid}
    else
      :ok = delete_value(pdl, pid)
      {:error, :not_found}
    end
  end
  defp resolve_value(value, _key, _pdl), do: {:ok, value}
end
