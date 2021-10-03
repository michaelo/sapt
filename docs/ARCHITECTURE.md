Architectural decisions log
==============================

This document shall serve as a log and work-area of all major design and architecturally significant decisions and thoughtwork.

Stable
----------

This sections is reserved for features and decisions that are now considered to serve for the longevity of the project.

### Overarching goals

* Simple - no hidden data, clear configuration
* Performant - it shall spin up fast, and once it's finished it shall no longer occupy any resources
* Unobtrusive
* Private - you own your data


### Major early-on design decisions 

* ...

### ...

* ...

Unstable
----------

This sections is reserved for features and decisions which have not rached maturity yet.

### Variable handling

The tool shall support access to environment variables (?) as well as be able to: 1) read variables from .env-files and populate variables based on response from tests.

Sources of variables:

* OS environment
  * TBD: Are there any security/privacy issues here?
* .env-files
  * TBD: Shall they be allowed in any folder, and thus be similarily scoped? We aim for simplicity and clearity - we don't want unintended variables set by mistake due to e.g. running tests from multiple folders
  * Proposal: Any top-level folders passed as direct arguments to 
  * Will need to handle "collisions" where same variable is set from multiple sources. Suggested order, from least to most significant: OS env, .env, parsed. Furthermore, definitions from subfolder .envs override parent .envs.
* Parsed from results of earlier tests

### Playbooks

* The tool shall support composing a file to serve as a playbook of tests to be executed along with certain properties.
  * An ordered list of tests to be executed
  * An optional number of times each test shall be repeated, default: 1
  * An optional set of variables
* Output: ...


### File-injection into payload

To support passing either larger sets of data, or perhaps a binary payload of some sorts it might be beneficiary to be able to simply point to an external file.

Proposed syntax:

    > GET https://my.service/endpoint
    Content-Type: image/jpeg
    # Specife a file by adding a path-reference directly after the payload-separator:
    - myfile.jpg
    < 200