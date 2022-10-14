defmodule PayDayLoan.Support.TestImplementation do
  # common implementation used for test caches
  alias PayDayLoanTest.Support.LoadHistory

  defmacro __using__(_opts \\ []) do
    quote do
      @behaviour PayDayLoan.Loader

      @key_that_shall_be_replaced "key that shall be replaced"
      @key_that_loads_too_slowly "key that loads too slowly"
      @key_that_reloads_slowly "key that reloads slowly"
      @key_that_does_not_exist "key that does not exist"
      @key_that_will_not_new "key that will not new"
      @key_that_will_not_refresh "key that will not refresh"
      @key_that_returns_ignore_on_new "key that returns ignore on new"
      @key_that_returns_ignore_on_refresh "key that returns ignore on refresh"
      @key_that_is_removed_from_backend "key that is removed from backend"
      @key_that_times_out_during_bulk_load "key that times out during bulk load"

      # we'll refuse to load this key
      def key_that_shall_not_be_loaded do
        "key that shall not be loaded"
      end

      # this one will get a new pid
      def key_that_shall_be_replaced do
        @key_that_shall_be_replaced
      end

      # this one will take too long to load
      def key_that_loads_too_slowly do
        @key_that_loads_too_slowly
      end

      # this key takes more than one cycle to refresh but does not time out
      def key_that_reloads_slowly do
        @key_that_reloads_slowly
      end

      # this one will fail the key cache check
      def key_that_does_not_exist do
        @key_that_does_not_exist
      end

      # this key will return an error on new
      def key_that_will_not_new do
        @key_that_will_not_new
      end

      # this key will return an error on refresh
      def key_that_will_not_refresh do
        @key_that_will_not_refresh
      end

      # this key will return :ignore on new
      def key_that_returns_ignore_on_new do
        @key_that_returns_ignore_on_new
      end

      # this key will return :ignore on refresh
      def key_that_returns_ignore_on_refresh do
        @key_that_returns_ignore_on_refresh
      end

      # this key gets removed on the backend and we pretend it's no longer
      # available
      def key_that_is_removed_from_backend do
        @key_that_is_removed_from_backend
      end

      # this key causes a timeout crash in the loader itself
      def key_that_times_out_during_bulk_load do
        @key_that_times_out_during_bulk_load
      end

      def bulk_load(keys) do
        LoadHistory.loaded(keys)

        if Enum.any?(keys, fn k -> k == key_that_times_out_during_bulk_load() end) do
          # simulate a typical pattern match error that happens when we get a timeout
          # during bulk load and don't recover gracefully
          :ok = :timed_out
        end

        keys =
          keys
          |> Enum.filter(fn k ->
            k != key_that_shall_not_be_loaded()
          end)

        Enum.map(keys, fn key -> {key, key} end)
      end

      def new(key = @key_that_will_not_new, value) do
        LoadHistory.new(key, value)
        {:error, :load_failed}
      end

      def new(key = @key_that_loads_too_slowly, value) do
        LoadHistory.new(key, value)
        :timer.sleep(500)
        {:error, :load_failed}
      end

      def new(key = @key_that_returns_ignore_on_new, value) do
        LoadHistory.new(key, value)
        :ignore
      end

      def new(key = @key_that_is_removed_from_backend, value) do
        if LoadHistory.news() == [] do
          LoadHistory.new(key, value)
          on_new(key, value)
        else
          {:error, :load_failed}
        end
      end

      def new(key, value) do
        LoadHistory.new(key, value)
        on_new(key, value)
      end

      def refresh(old_value, key = @key_that_will_not_refresh, value) do
        LoadHistory.refresh(old_value, key, value)
        on_remove(key, old_value)
        # return error
        {:error, :refresh_failed}
      end

      def refresh(old_value, key = @key_that_returns_ignore_on_refresh, value) do
        LoadHistory.refresh(old_value, key, value)
        on_remove(key, old_value)
        # return ignore
        :ignore
      end

      def refresh(old_value, key = @key_that_shall_be_replaced, value) do
        LoadHistory.refresh(old_value, key, value)
        # replace existing value
        on_replace(old_value, key, value)
      end

      def refresh(old_value, key = @key_that_reloads_slowly, value) do
        LoadHistory.refresh(old_value, key, value)
        :timer.sleep(100)
        on_replace(old_value, key, value)
      end

      def refresh(old_value, key, value) do
        LoadHistory.refresh(old_value, key, value)
        on_update(old_value, key, value)
      end

      def key_exists?(@key_that_does_not_exist), do: false
      def key_exists?(_key), do: true
    end
  end
end
