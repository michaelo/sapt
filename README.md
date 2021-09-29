API-tester
==============

A simple tool to counter e.g. Postman.

Usage: Simple
-------------
    testsuite/01-mytest.pi contents:
    
    > GET https://api.warnme.no/api/stats
    Content-Type: application/json
    < 200

    % apitester testsuite/01-mytest.pi
    1/1 testsuite/01-mytest.pi (10x) [0.1s-0.4s] avg. 0.2s    : OK


Usage: playbook
-----------
    myplay.book contents:
    myproj/auth.pi 1
    myproj/api_get.pi 100


Design goals:
------------
* Only you should own and control your data - e.g. any version control and data sharing is up to you.
* Tests should be easily written and arranged - no hidden headers or such
* Support easy use of secrets and common variables/definition


Must fix to be usable AKA pri-TODO:
-------------
* Parse results and store as variables
* Support variables - both from env and from previous tasks
* Output useful errors when it fails (HTTP-code, helpful labels for the most common ones, and the response)
* Input-file parser must support CRLF as line end

TODO:
------------
* Support .env-files or similar to pass in predefined variables
* Check for Content-Type of response and support pretty-printing of at least JSON, preferrably also HTML and XML
* -v also prints variable-extraction results
* Allow support for OS-environment variables. Control by flag?
* Support "playlist"-files to defined e.g. order and repetitions?
* Support both keeping variables between as well as explicitly allowing sandboxing of tests
* Support paralllel requests? Both for general perceived performance as well as for stress-tests
* Support response-time as test-prereq? Perhaps in playlist
* Test/verify safety of string lengths: parsing + how we add 0 for c-interop
* Verbose-flag, which also activates curl-verbosity
* Support list of curl-commands as output?
* Doucment all limitations: sizes of all fields etc

Later:
------
* Performant, light-weight GUI? Plotting performance for stress tests and such.
* Test feature flags based on comptime-parsing a feature-file

Thanks / attributions:
--------
* cURL - the workhorse
* zig - a fun and useful language of which this project is my first deliverable
