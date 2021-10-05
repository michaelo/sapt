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

### Test file structure/specification

    TBD: Pr now described in README.md, see "Test-file specification"

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

Exploration of an all-encompassing playbook-format: 

    # Exploration of integrated tests in playbooks
    # Can rely on newline+> to indicate new tests.
    # Can allow for a set of variables defined at top before first test as well.
    #     The format should allow combination of file-references as well as inline definitions
    # Syntax (proposal):
    #    Include file directive starts with @
    #       If file-ext matches test-file then allow for repeat-counts as well
    #       If file-ext matches .env then treat as envs
    #       If file-ext matches playbook-file then include playbook? TBD. Must avoid recursion-issues and such. Not pri. Pr now: report as error
    #    Included tests starts with a line with '>' and ends with a line with either '@' (new include) or new '>' (new test). Otherwise treated exactly as regular test-files. Repeat-control?
    #    If line not inside inline-test, and not starts with @, check for = and if match treat as variable definition
    #    Otherwise: syntax error
    #    
    # Load env from file
    @myservice/.env
    # Define env in-file
    MY_ENV=Woop

    # Refer to external test
    @generic/01-oidc-auth.pi

    # Refer to external test with repeats
    @myservice/01-getentries.pi 50

    # Inline-test 1
    > GET https://my.service/api/health
    Accept: application/json
    Cookie: SecureToken={{oidc_token}}
    < 200 OK
    # Store entire response:
    EXTRACTED_ENTRY=()

    # Refer to external test inbetween inlines
    @myservice/01-getentries.pi 50

    # Another inline-test
    > GET https://my.service/api/health
    Accept: application/json
    Cookie: SecureToken={{oidc_token}}
    < 200


### File-injection into payload

To support passing either larger sets of data, or perhaps a binary payload of some sorts it might be beneficiary to be able to simply point to an external file.

Proposed syntax:

    > GET https://my.service/endpoint
    Content-Type: image/jpeg
    # Specife a file by adding a '@'+path-reference directly after the payload-separator:
    -@myfile.jpg
    < 200