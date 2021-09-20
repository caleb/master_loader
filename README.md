# ![](http://i.imgur.com/ZdJKtj1.png) MasterLoader

[![Build Status](https://travis-ci.org/sheerun/dataloader.svg?branch=master)](https://travis-ci.org/sheerun/dataloader) [![codecov](https://codecov.io/gh/sheerun/dataloader/branch/master/graph/badge.svg)](https://codecov.io/gh/sheerun/dataloader)

MasterLoader is a generic utility based on [Dataloader](https://github.com/sheerun/dataloader), to be used as part of your application's data fetching layer to provide a simplified and consistent API to perform batching and caching within a request. It is heavily inspired by [Facebook's dataloader](https://github.com/facebook/dataloader).

## Getting started

First, install MasterLoader using bundler:

```ruby
gem "master_loader"
```

To get started, instantiate `MasterLoader`. Each `MasterLoader` instance represents a unique cache. Typically instances are created per request when used within a web-server. To see how to use with GraphQL server, see section below.

MasterLoader is dependent on [concurrent-ruby](https://github.com/ruby-concurrency/concurrent-ruby) which you can use freely for batch-ready code (e.g. loader can return a `Future` that returns a `Future` that returns a `Future`). MasterLoader will try to batch most of them.

## Basic usage

```ruby
# It will be called only once with ids = [0, 1, 2]
loader = MasterLoader.new do |ids|
  User.find(*ids)
end

# Schedule data to load
promise_one = loader.load(0)
promise_two = loader.load_many([1, 2])

# Get promises results
user0 = promise_one.value!
user1, user2 = promise_two.value!
```

## Using with GraphQL

You can pass loaders passed inside [`context`](https://rmosolgo.github.io/graphql-ruby/queries/executing_queries).

```ruby
UserType = GraphQL::ObjectType.define do
  field :name, types.String
end

QueryType = GraphQL::ObjectType.define do
  name "Query"
  description "The query root of this schema"

  field :user do
    type UserType
    argument :id, !types.ID
    resolve ->(obj, args, ctx) {
      ctx[:user_loader].load(args["id"])
    }
  end
end

Schema = GraphQL::Schema.define do
  lazy_resolve(Concurrent::Promises::Future, :'value!')

  query QueryType
end

context = {
  user_loader: MasterLoader.new do |ids|
    User.find(*ids)
  end
}

Schema.execute("{ user(id: 12) { name } }", context: context)
```

## Batching

You can create loaders by providing a batch loading function.

```ruby
user_loader = MasterLoader.new { |ids| User.find(*ids) }
```

A batch loading block accepts an Array of keys, and returns a Promise which resolves to an Array or Hash of values.

`MasterLoader` will coalesce all individual loads which occur until first `#value!` (or `#value`, `#wait`, `#touch` or other `Concurrent::Promises::Future` method that blocks waiting for a result) is called on any promise returned by `#load` or `#load_many`, and then call your batch function with all requested keys.

```ruby
user_loader.load(1)
  .then { |user| user_loader.load(user.invited_by_id) }
  .then { |invited_by| "User 1 was invited by ${invited_by[:name]}" }

# Elsewhere in your backend
user_loader.load(2)
  .then { |user| user_loader.load(user.invited_by_id) }
  .then { |invited_by| "User 2 was invited by ${invited_by[:name]}" }
```

A naive solution is to issue four SQL queries to get required information, but with `MasterLoader` this application will make at most two queries (one to load users, and second one to load invites).

`MasterLoader` allows you to decouple unrelated parts of your application without sacrificing the performance of batch data-loading. While the loader presents an API that loads individual values, all concurrent requests will be coalesced and presented to your batch loading function. This allows your application to safely distribute data fetching requirements throughout your application and maintain minimal outgoing data requests.

### Batch function

A batch loading function accepts an Array of keys, and returns Array of values or Hash that maps from keys to values (or a [Concurrent::Promises::Future](https://github.com/ruby-concurrency/concurrent-ruby) that returns such Array or Hash). There are a few constraints that must be upheld:

* The Array of values must be the same length as the Array of keys.
* Each index in the Array of values must correspond to the same index in the Array of keys.
* If Hash is returned, it must include all keys passed to batch loading function

For example, if your batch function was provided the Array of keys: `[ 2, 9, 6 ]`, you could return one of following:

```ruby
[
  { id: 2, name: "foo" },
  { id: 9, name: "bar" },
  { id: 6, name: "baz" }
]
```

```ruby
{
  2 => { id: 2, name: "foo" },
  9 => { id: 9, name: "bar" },
  6 => { id: 6, name: "baz" }
}
```

## Caching

`MasterLoader` provides a memoization cache for all loads which occur withing single instance of it. After `#load` is called once with a given key, the resulting Promise is cached to eliminate redundant loads.

In addition to relieving pressure on your data storage, caching results per-request also creates fewer objects which may relieve memory pressure on your application:

```
promise1 = user_loader.load(1)
promise2 = user_loader.load(1)
promise1 == promise2 # => true
```

### Caching per-request

`MasterLoader` caching does not replace Redis, Memcache, or any other shared application-level cache. `MasterLoader` is first and foremost a data loading mechanism, and its cache only serves the purpose of not repeatedly loading the same data in the context of a single request to your Application. To do this, it maintains a simple in-memory memoization cache (more accurately: `#load` is a memoized function).

Avoid multiple requests from different users using the same `MasterLoader` instance, which could result in cached data incorrectly appearing in each request. Typically, `MasterLoader` instances are created when a request begins, and are not used once the request ends.

See [Using with GraphQL](https://github.com/sheerun/dataloader#using-with-graphql) section to see how you can pass dataloader instances using context.

### Caching errors

If a batch load fails (that is, a batch function throws or returns a rejected Promise), then the requested values will not be cached. However if a batch function returns an Error instance for an individual value, that Error will be cached to avoid frequently loading the same Error.

In some circumstances you may wish to clear the cache for these individual Errors:

```ruby
user_loader.load(1).rescue do |error|
  user_loader.cache.delete(1)
  raise error
end
```

### Disabling cache

In certain uncommon cases, a `MasterLoader` which does not cache may be desirable. Calling `MasterLoader.new({ cache: nil }) { ... }` will ensure that every call to `#load` will produce a new Promise, and requested keys will not be saved in memory.

However, when the memoization cache is disabled, your batch function will receive an array of keys which may contain duplicates! Each key will be associated with each call to `#load`. Your batch loader should provide a value for each instance of the requested key.

```ruby
loader = MasterLoader.new(cache: nil) do |keys|
  puts keys
  some_loading_function(keys)
end

loader.load('A')
loader.load('B')
loader.load('A')

// > [ 'A', 'B', 'A' ]
```

## API

### `MasterLoader`

`MasterLoader` is a class for fetching data given unique keys such as the id column (or any other key).

Each `MasterLoader` instance contains a unique memoized cache. Because of it, it is recommended to use one `MasterLoader` instance **per web request**. You can use more long-lived instances, but then you need to take care of manually cleaning the cache.

You shouldn't share the same dataloader instance across different threads. This behavior is currently undefined.

### `MasterLoader.new(**options = {}, &batch_load)`

Create a new `MasterLoader` given a batch loading function and options.

* `batch_load`: A block which accepts an Array of keys, and returns Array of values or Hash that maps from keys to values (or a [Promise](https://github.com/lgierth/promise.rb) that returns such value).
* `options`: An optional hash of options:
  * `:key` **(not implemented yet)** A function to produce a cache key for a given load key. Defaults to function { |key| key }. Useful to provide when objects are keys and two similarly shaped objects should be considered equivalent.
  * `:cache` An instance of cache used for caching of promies. Defaults to `Concurrent::Map.new`.
    - The only required API is `#compute_if_absent(key)`).
    - You can pass `nil` if you want to disable the cache.
    - You can pass pre-populated cache as well. The values can be Promises.
  * `:max_batch_size` Limits the number of items that get passed in to the batchLoadFn. Defaults to `INFINITY`. You can pass `1` to disable batching.

### `#load(key)`

**key** [Object] a key to load using `batch_load`

Returns a [Future](https://github.com/ruby-concurrency/concurrent-ruby) of computed value.

You can resolve this promise when you actually need the value with `promise.value!`.

All calls to `#load` are batched until the first `#value!` is encountered. Then is starts batching again, et cetera.

### `#load_many(keys)`

**keys** [Array<Object>] list of keys to load using `batch_load`

Returns a [Future](https://github.com/ruby-concurrency/concurrent-ruby) of array of computed values.

To give an example, to multiple keys:

```ruby
promise = loader.load_many(['a', 'b'])
object_a, object_b = promise.value!
```

This is equivalent to the more verbose:

```ruby
promise = Concurrent::Promises.zip_futures(loader.load('a'), loader.load('b')).then {|*results| results}
object_a, object_b = promise.value!
```

### `#cache`

Returns the internal cache that can be overridden with `:cache` option (see constructor)

This field is writable, so you can reset the cache with something like:

```ruby
loader.cache = Concurrent::Map.new
```

## License

MIT
