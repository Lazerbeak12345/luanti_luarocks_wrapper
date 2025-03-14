# Luanti Luarocks Wrapper

Do you want to depend on a luarock?

Don't. Please don't. Luanti doesn't make it easy.

But what if you must? What if you require something so complicated, so advanced, that it would take months to work on?
What if security depends on the correct implimentation of this mod?
What if ... someone already did the work for you, in a luarock, but they don't even know what luanti _is_, and they don't seem interested in packaging thier rock as a luanti mod?

That, my friend, is the _only_ reason you should use this, the Luanti Luarocks Wrapper.

## What problems does this mod fix?

This mod allows you to "wrap" a LuaRocks package as a Luanti mod.

## What problems does it not fix?

There are certian things not available from within the Luanti mod sandbox. It is not possible to provide a subset of these things, and if the LuaRocks package you need requires that, this Luanti mod can't help you.

Should I release the CLI tooling, I will have a partial solution, but you would still need the user to mark your mod as trusted.

A few examples, as I find them:

- Rocks with external dependencies
- Rocks that require compilation/are not written in 100% lua
