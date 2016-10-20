This is a sample Rails 5.0.0.1 app that demonstrates a simple isolated reproduction of
a Rails app that uses threaded-concurrency (via ruby-concurrent) inside
a Rails action. The rails generation was with
`--skip-active-record --skip-turbolinks --skip-spring`.

This README explains the use case, findings for various Rails config
settings (some fail disastrously), and questions/requests for Rails issue.

--------------

I sometimes need/want to use some basic threaded concurrency inside a rails action --
execute some things concurrently, wait for them all to complete before returning
the response.

Here is a basic isolated fake example, as used in this demo app:

~~~ruby
  # action method
  def example
    futures = 3.times.collect do
      Concurrent::Future.execute do
        Rails.application.reloader.wrap do
          SomeWorker.new.value
        end
      end
    end

    @example_values = futures.collect(&:value)
  end
~~~

This is a useful thing to do you really do need to wait for those "SomeWorker"
results to return a response, but they are a bit slow, and can be performed
concurrently/in parallel. (Even with MRI GIL this is effective when they are
slow because of IO).

In Rails 4.x, under default configuration in an app, in development mode,
this would _mostly_ work fine, but would _occasionally_ raise a weird
exception involving "class definition has changed" or something, I'm afraid I
forget the exact exception class/message and can't find it.

In Rails 4.x, if you correct set up the under-documented and inter-related
relevant config keys --  `config.eager_load`, `config.auto_load` and
`config.cache_classes` -- you could make it work entirely correctly, probably
by giving up development-mode class reloading though.

In Rails 4.x, it works fine under default production configuration, and as
far as I know does in Rails 5 too.

But in development mode, tn Rails 5.0, due to new autoloading logic, the "failure mode" has changed --
if you don't configure things correct, instead of (Rails 4) getting mostly working
but occasionally weird exception -- you get (Rails 5) the worker thread hanging
forever (presumably a deadlock).

The app in this repo has `config/development.rb` set up to use ENV vars
to make testing under various config combinations more convenient.

Findings:

1. Under default generated app config

        config.cache_classes = false
        config.eager_load = false
        config.auto_load => not explicitly set

   Rails worker thread hangs forever on first request.


2. CONF_EAGER_LOAD=false CONF_CACHE_CLASSES=true

    Same, hangs forever on first request.

3. CONF_EAGER_LOAD=true CONF_CACHE_CLASSES=false rails serve

    Works fine on initial requests. However, if you change
    the source of a file on disk, that gets referenced in
    one of the child threads, on _next_ request the worker
    thread will hang forever.

4. CONF_EAGER_LOAD=true CONF_CACHE_CLASSES=true

    This is the magic configuration that makes it work, at the cost of
    giving up on development-mode class reloading, you need to restart
    the app to pick up any changes.

Additional irrelevant config or logic:

* The setting for `config.auto_load` is irrelevant. In each of the above 4 cases,
whether `config.auto_load` was set to true, false, or unset (use default) made
no difference, `config.eager_load` and `config.cache_classes` were the only
settings that seemed to matter for this behavior.

* I was aware of `Rails.application.reloader` from seeing it used in a
  [sidekiq change](https://github.com/mperham/sidekiq/pull/2457). Without really
  understanding it, I tried wrapping my child threads like so:

      Concurrent::Future.execute do
        Rails.application.reloader.wrap do
          SomeWorker.new.value }
        end
      end

  That made no difference either, all observed behavior was the same in
  above 4 configuration combinations, with or without this `wrap`. I don't
  know if there's a more useful way to use the `reloader` for this use case,
  or if it's just irrelevant.

Issues for Rails team:

1. Is this a bug?

   I suspect the answer will be "no" -- it is no longer supported to use
   threads like this without turning off development-mode class reloading
   entirely.

   This is a bit annoying, as I much preferred having it _mostly_ working
   with occasional exceptions that made me restart the app, instead of
   needing to turn off dev-mode reloading to get it to work at all, and
   _always_ having to restart the app to pick up changes.

   However, it may be that's just how it is, as sad as it makes me. Nevertheless:

2. Can failure mode be better?

    The "failure mode" for doing it wrong of hanging forever/deadlocking
    is pretty annoying and confusing. It can take someone quite a while
    to figure out what's going on, and that it's even related to auto-loading
    at all.  Especially with concurrency getting easier to use for less
    experienced developers (hooray ruby-concurrent), I can see people
    getting _really_ stuck here they accidentally do it 'wrong' and get a
    mysterious deadlock.

    Is there any way to get a better failure mode, an actual quick fail with
    an exception with a useful class/message, instead of a hang forever/deadlock?

    Whether this is considered a 'bug' or a 'new feature' has to do with the
    intentions of whoever wrote the new autoloading stuff, I guess.

3. Documentation.

    All of these things need better documentation -- which has been
    true pre-Rails5 too, but with changes those of us who kind of
    sort of figured it out in Rails <5 could use it too.

    Save others the several hours I spent debugging my deadlock, investigating
    the issue, resulting in this here you are reading.

    I can't submit a doc PR myself, because I really don't understand
    well enough what's actually going on, or the intended behavior/configuration.

    Some suggested doc needs:

    * `config.eager_load`, `config.cache_classes` and `config.auto_load` have
       always been poorly-doc'd, especially their interactions with each other,
       and their defaults, which seem to depend on how others of them are set.
       Not only poorly doc'd, but fairly high 'churn' changing from Rails version
       to version.
        * For my use case, I only avoided deadlock with `eager_load` and
          `cache_classes` both true. Is there any reason at all to have
          one true and the other false? In what circumstances might
          this make sense, and what does it do?

        * Does `config.auto_load` do anything at all in Rails5, or has it
          become a no-op?  It didn't seem to have an effect on my problem
          case, but maybe it does in other cases? Or is it gone?

        * If it's true that you need to turn off dev-mode reloading in
          order to use threads inside a Rails action method (inside the request loop),
          and it's true that you do that with `eager_loading` and `cache_classes`
          both set to true, then some documentation to that effect would be
          welcome, and would save people some confusing debugging time.
          If i havne't actually figured out the right/best/only way to do this,
          and there are other options -- I'm prob not the only one who would
          appreciate some docs!

        * _test_ enviornments. Default generated Rails5 test env
          is `cache_classes==true`, `eager_load==false`. Rails 4
          had some generated comments in `config/test.rb`
          about `eager_load`: " If you are using a tool that
          preloads Rails for running tests, you may have to set it to true."

          A bit confusing and in my experience not entirely reliable advice in Rails 4.
          I believe a "tool that preloads rails for running tests" basically
          means "Capybara".  Rails5 no longer generates this hint, but still defaults
          `eager_load` to false. Is this going to cause problems with capybara?

          Concurrency problems with capybara are super frustrating to debug
          and figure out how to deal with them, so some instructions
          here would be much appreciated. Especially since the default setting
          is one that under my use case above still caused deadlocks.

    * Rails.application.reloader

      The only reason I knew this even existed, or anything at all about how to use
      it, is from the [sidekiq pr](https://github.com/mperham/sidekiq/pull/2457).

      The only reason it's in a sidekiq PR is because someone from Rails core
      team gave sidekiq hints/code, it would be unlikely for anyone who doens't
      already know the code to have known that it should be used, and the correct
      way to use it.

      It may be that `Rails.application.reloader` is entirely irrelevant to
      my use case -- some docs explaining what it is and how it use it could
      have saved me some time in figuring that out myself by experimenting.

      But clearly there are _some_ appropriate use cases for it in non-Rails-core code,
      like in sidekiq. some docs are needed so people not on Rails core team know when to use it,
      and how.

      Tagging @matthewd , because he suggested in the sidekiq PR that I open
      a Rails issue on documentation of the "executor/reloader API", and I'm
      hoping he has some input on the general reloading/concurrency issues
      above, since they look pretty intimately related to the executor/reloader
      in Rails5.


