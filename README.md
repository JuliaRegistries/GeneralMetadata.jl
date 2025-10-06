# GeneralMetadata

Aggregate some helpful data about Julia's package ecosystem that isn't immediately available
from the General registry itself.

> [!WARNING]
> Work in progress, and not a final location for this work. If successful, this will hopefully
> be incorporated into the JuliaRegistries org or RegistryCI or BinaryBuilder or as an action
> directly on the General registry itself, or perhaps as some mix of the above.

## The additional metadata:

* **Registration/tag timestamps**: These will likely be used as input for Dependabot
* **Package license identification** (if possible): Yet todo
* **Upstream component identification**: When a Julia package directly _provides_
     an upstream project, it's helpful to know which packages those are and the
     versions thereof.

