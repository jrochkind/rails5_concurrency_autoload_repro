class ExampleController < ApplicationController
  def example
    futures = 3.times.collect do
      Concurrent::Future.execute { SomeWorker.new.value }
    end

    @example_values = futures.collect(&:value)
  end
end
