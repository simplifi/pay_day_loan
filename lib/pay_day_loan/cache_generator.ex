defmodule PayDayLoan.CacheGenerator do
  # Macro implementation for PDL - should not be called from
  # the outside world.
  @moduledoc false

  @doc false
  @spec compile(Keyword.t) :: Macro.t
  def compile(opts) when is_list(opts) do
    callback_module = opts
    |> Keyword.get(:callback_module)
    |> determine_callback_module

    # build the config struct with defaults overridden by
    # values from opts
    pdl = opts
    |> merge_opts(%PayDayLoan{callback_module: callback_module})
    |> PayDayLoan.merge_defaults

    quoted_pdl = quoted_struct(pdl)

    [
      generate_pdl(quoted_pdl),
      generate_shortcuts()
    ]
  end

  # these are the main functions generated by the macro - they
  # define the pay_day_loan function which just returns the
  # pdl struct that was generated from the options
  defp generate_pdl(quoted_pdl) do
    quote location: :keep do
      @doc "PayDayLoan-generated cache configuration"
      @spec pay_day_loan :: PayDayLoan.t
      def pay_day_loan do
        unquote(quoted_pdl)
      end

      @doc "Alias of pay_day_loan/0"
      @spec pdl :: PayDayLoan.t
      defdelegate pdl, to: __MODULE__, as: :pay_day_loan
    end
  end

  # these are shortcut functions that basically just
  # delegate to PayDayLoan with the generated pdl as the
  # first argument
  #
  # there may be a way to do this using import
  defp generate_shortcuts do
    quote location: :keep do
      @doc "Wraps `PayDayLoan.get/2`"
      @spec get(PayDayLoan.key) :: {:ok, term} | {:error, PayDayLoan.error}
      def get(key) do
        PayDayLoan.get(pdl(), key)
      end

      @doc "Wraps `PayDayLoan.peek/2`"
      @spec peek(PayDayLoan.key) :: {:ok, term} | {:error, :not_found}
      def peek(key), do: PayDayLoan.peek(pdl(), key)

      @doc "Wraps `PayDayLoan.peek_load_state/2`"
      @spec peek_load_state(PayDayLoan.key) :: nil | PayDayLoan.LoadState.t
      def peek_load_state(key), do: PayDayLoan.peek_load_state(pdl(), key)

      @doc """
      Returns a map of load states and the number of keys in each state

      Useful for instrumentation
      """
      @spec load_state_stats() :: %{}
      def load_state_stats, do: PayDayLoan.load_state_stats(pdl())

      @doc "Wraps `PayDayLoan.query_load_state/2`"
      @spec query_load_state(PayDayLoan.key) :: PayDayLoan.LoadState.t
      def query_load_state(key), do: PayDayLoan.query_load_state(pdl(), key)

      @doc "Wraps `PayDayLoan.supervisor_specification/1`"
      @spec supervisor_specification() :: Supervisor.Spec.spec
      def supervisor_specification do
        PayDayLoan.supervisor_specification(pdl())
      end

      @doc "Wraps `PayDayLoan.uncache_key/2`"
      @spec uncache_key(PayDayLoan.key) :: :ok
      def uncache_key(key), do: PayDayLoan.uncache_key(pdl(), key)

      @doc "Wraps `PayDayLoan.with_value/4`"
      @spec with_value(PayDayLoan.key, ((term) -> term), (() -> term)) :: term
      def with_value(
        key,
        found_callback,
        not_found_callback \\ fn -> {:error, :not_found} end
      ) do
        PayDayLoan.with_value(pdl(), key, found_callback, not_found_callback)
      end

      @doc "Wraps `PayDayLoan.size/1`"
      @spec size :: non_neg_integer
      def size do
        PayDayLoan.size(pdl())
      end

      @doc "Wraps `PayDayLoan.request_load/2`"
      @spec request_load(PayDayLoan.key | [PayDayLoan.key]) :: :ok
      def request_load(key_or_keys) do
        PayDayLoan.request_load(pdl(), key_or_keys)
      end

      @doc "Wraps `PayDayLoan.keys/1`"
      @spec keys :: [PayDayLoan.key]
      def keys do
        PayDayLoan.keys(pdl())
      end

      @doc """
      Wraps `PayDayLoan.pids/1`

      This is a legacy API method and may be deprecated.  Use `values/0`
      """
      @spec pids :: [pid]
      def pids do
        PayDayLoan.pids(pdl())
      end

      @doc "Wraps `PayDayLoan.values/1`"
      @spec values :: [term]
      def values do
        PayDayLoan.values(pdl())
      end

      @doc "Wraps `PayDayLoan.reduce/3`"
      @spec reduce(term, (({PayDayLoan.key, pid}, term) -> term)) :: term
      def reduce(acc0, reducer)
      when is_function(reducer, 2) do
        PayDayLoan.reduce(pdl(), acc0, reducer)
      end

      @doc "Wraps `PayDayLoan.cache/3`"
      @spec cache(PayDayLoan.key, pid) :: :ok | {:error, pid}
      def cache(key, pid) do
        PayDayLoan.cache(pdl(), key, pid)
      end
    end
  end

  defp determine_callback_module(nil) do
    message = "You must supply a callback module.  E.g.,:" <>
      " `use PayDayLoan, callback_module: MyCacheLoader`"
    raise ArgumentError, message: message
  end
  defp determine_callback_module({:__aliases__, _meta, module}) do
    Module.concat(module)
  end

  defp merge_opts(opts, pdl) do
    opts
    |> Keyword.delete(:callback_module) # already merged
    |> Enum.reduce(pdl, fn({k, v}, acc) ->
      Map.put(acc, k, v)
    end)
  end

  # turns a struct into a quoted expression
  defp quoted_struct(struct) do
    struct_module = struct.__struct__
    meta = {
      :__aliases__,
      [alias: false],
      Enum.map(Module.split(struct_module), &String.to_atom/1)
    }
    new_kv = struct |> Map.from_struct |> Enum.into([])
    {:%, [], [meta, {:%{}, [], new_kv}]}
  end
end
