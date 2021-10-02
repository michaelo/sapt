sapt - Simple API testing tool
==============

A simple tool to counter e.g. Postman.

Usage: Simple
-------------
    testsuite/01-mytest.pi contents:
    
    > GET https://api.warnme.no/api/status
    Content-Type: application/json
    < 200

    % sapt testsuite/01-mytest.pi
    1/1 testsuite/01-mytest.pi                                : OK

    % sapt -h
    -- shows help


Usage: playbook (draft, not implemented)
-----------
    myplay.book contents:
    myproj/auth.pi 1
    myproj/api_get.pi 100


Design goals:
------------
* Only you should own and control your data - e.g. any version control and data sharing is up to you.
* Tests should be easily written and arranged - no hidden headers or such
* Support easy use of secrets and common variables/definitions


Must fix to be usable AKA pri-TODO:
-------------
* Support variables: missing from OS env
* Output useful errors when it fails (HTTP-code, helpful labels for the most common ones, and the response)


TODO:
------------
* Support .env-files or similar to pass in predefined variables: currently only support explicitly passing it through -i=path
* Check for Content-Type of response and support pretty-printing of at least JSON, preferrably also HTML and XML
* Allow support for OS-environment variables. Control by flag?
* Support "playlist"-files to defined e.g. order and repetitions?
    * Playlist/playblook shall also support setting variables
* Support both keeping variables between (default) as well as explicitly allowing sandboxing (flag) of tests
* Support parallel requests? Both for general perceived performance as well as for stress-tests (low pri)
* Support response-time as test-prereq? Perhaps in playlist (low pri)
* Test/verify safety of string lengths: parsing + how we add 0 for c-interop
* Support list of curl-commands as output?
* Doucment all limitations: sizes of all fields etc
* TBD: Possibility to set "verbose" only for a specific test? Using e.g. the test-sequence-number?
* Support handling encrypted variables?
* Support/use coloring for improved output
* ...

Later:
------
* Performant, light-weight GUI? Plotting performance for stress tests and such.
* Test feature flags based on comptime-parsing a feature-file

Terminology:
------
* test - the particular file to be performed. A test can result in "OK" or "ERROR"
* playbook - a particular recipe of tests, their order and other parameters to be executed in a particular fashion

Limitations:
------
Due to the effort to avoid heap-usage, a set of discrete limitations are currently cheracteristic for the tool. I will very likely revise a lot of these decisions going forward - but here they are:

* Max number of tests to process in a given run: 128
* Max length for any file path: 1024
* Test-specific parameters:
    * Max number of headers: 32
    * Max length for a given HTTP-header: 8K
    * Max number of variables+functions in a given test: 64
    * Max length of a function response: 1024
    * Max length of a variable key: 128
    * Max length of a variable value: 8K
    * Max URL length: 2048B
    * Max size of payload: 1M
    * ...


Test-file specification:
--------

    <input section>
    <optional set of headers>
    <optional payload section>
    <response section>
    <optional set of >

Comments:

    # Comment - must be start of line. Can be used everywhere except of in payload-section

Variables:

    {{my_var}}

Functions:

A couple of convenience-functions are implemented. The argument can consist of variables.

    {{base64enc(string)}}
    # Example:
    Authorization: basic {{base64enc({{username}}:{{password}})}}


Input section:

    # '>' marks start of 'input'-section, followed by HTTP verb and URL
    > POST https://some.where/
    # List of HTTP-headers, optional
    Content-Type: application/json
    Accept: application/json

Payload section, optional:

    # '-' marks start of payload-section
    -
    {"some":"data}

Output section:

    # <Expected HTTP code> [optional string to check response for it to be considered successful]
    < 200 optional text
    # HTTP-code '0' is "don't care"
    < 0

Set of variable extraction expressions, optional:
    # Key=expression
    #   expression format: <text-pre><group-indicator><text-post>
    # Expression shall consists of a string representing the output, with '()' indicating the part to extract
    AUTH_TOKEN="token":"()"


Thanks / attributions:
--------
* cURL - the workhorse
* zig - a fun and useful language of which this project is my first deliverable


