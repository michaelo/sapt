API-tester
==============

A simple tool to counter e.g. Postman.

Usage:
-------------
    testsuite/01-mytest.pi contents:
    
    > GET https://api.warnme.no/api/stats
    Content-Type: application/json
    < 200

    % apitester testsuite/01-mytest.pi
    1/1 testsuite/01-mytest.pi (10x) [0.1s-0.4s] avg. 0.2s    : OK


Design goals:
------------
* Only you should own and control your data - e.g. any version control and data sharing is up to you.
* Tests should be easily written and arranged - no hidden headers or such
* Support easy use of secrets and common variables/definition


TODO:
------------
* Support .env-files or similar to pass in predefined variables
* Allow support for OS-environment variables. Control by flag?
* Support "playlist"-files to defined e.g. order and repetitions?
* Support both keeping variables between as well as explicitly allowing sandboxing of tests
* Support paralllel requests? Both for general perceived performance as well as for stress-tests
* Support response-time as test-prereq? Perhaps in playlist

Later:
------
* Performant, light-weight GUI? Plotting performance for stress tests and such.

Thanks / attributions:
--------
* cURL - the workhorse
* zig - a fun and useful language of which this project is my first deliverable
