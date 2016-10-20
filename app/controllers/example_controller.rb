class ExampleController < ApplicationController
  def example
    @example_values = 3.times.collect do
      SomeWorker.new.value
    end
  end
end
