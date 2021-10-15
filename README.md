sapt - A simple tool for API testing
==============
*Att: I'm testing different intro-texts to test what communicates the intention the best*

sapt aims to be a simple tool to help with API-testing and similar use cases. It focuses on making it easy for developers to compose, organize and perform tests/requests in an open, reliable and source-control friendly way.

sapt *"is not"* a full-fledged GUI-based do-anything tool, but rather a focused command line utility.


Usage: Basic
-------------

sapt requires you to organise your requests in individual files. Those files may be gathered in folders to create test suites.
    
testsuite/01-mytest.pi contents:
    
    > GET https://api.warnme.no/api/status
    < 200

Running a single test:

    % sapt testsuite/01-mytest.pi
    1/1 testsuite/01-mytest.pi                                : OK

Help:

    % sapt -h


sapt can take multiple arguments, both files and folders. The entire input-set will be sorted alphanumerically, thus you can dictate the order of execution by making sure the names of the scripts reflects the order:

* suite/01-auth.pi
* suite/02-post-entry.pi
* suite/03-get-posted-entry.pi
* suite/04-delete-posted-entry.pi

*Note: playbooks provides a way to override this.*

<!--

Why oh why
----------------

    You: Why should I use this tool?
    
    Me: Good question, I'm glad you asked!
        There's a good chance you shouldn't. There are several well established
        alternatives you should consider instead. E.g. Postman, httpier, or 
        perhaps cURL.
    
    You: ... ok? ...
    
    Me: But, if you should find those tools either to heavy to run, too
        unpredictable with regards to where your data may be stored, or simply
        just too slow or complex to run or compose tests for, sapt might be of
        interest.
    
    You: Go on...

    Me: sapt is a lightweight tool, both with regards to runtime requirements,
        as well as its' feature set. It also provides you with full control of
        your own data. See "Design goals" further down, or
        "docs/COMPARISONS.md" to see what sapt focuses on. 

    You: I've tried it and: (pick a choice)
        a) I loved it
            Me: Awesome!
        b) I hated it
            Me: No worries. Take care!
-->


Usage: Complex
----------------

Assuming you first have to get an authorization code from an auth-endpoint, which you will need in other tests.

Let's say you have the following files:

* myservice/.env
* myservice/01-auth.pi
* myservice/02-get-data.pi

### Set up variables: myservice/.env

    OIDC_USERNAME=myoidcclient
    OIDC_PASSWORD=sup3rs3cr3t
    USERNAME=someuser
    PASSWORD=supersecret42

### Get the auth-token: myservice/01-auth.pi

    > POST https://my.service/api/auth
    Authorization: Basic {{base64enc({{OIDC_USERNAME}}:{{OIDC_PASSWORD}})}}
    Content-Type: application/x-www-form-urlencoded
    -
    grant_type=password&username={{USERNAME}}&password={{PASSWORD}}&scope=openid%20profile
    < 200
    id_token="id_token":"()"

Provided that the auth-endpoint will return something like this:

    {"access_token": "...", "id_token":"...", "...", ...}

... the test will then set the id_token-variable, allowing it to be referred in subsequent tests.


### Get data from service using data from previous test: myservice/02-get-data.pi
    
    > GET https://my.app/api/entry
    Cookie: SecurityToken={{id_token}}
    < 200


### Finally, Run the testsuite

    sapt -i=myservice/.env myservice

Output:

    1: myservice/01-auth.pi                                 :OK (HTTP 200)
    2: myservice/02-get-data.pi                             :OK (HTTP 200)
    ------------------
    2/2 OK
    ------------------
    FINISHED - total time: 0.189s

*Tips: You can add -v or -d for more detailed output*

Usage: playbook
-----------
myplay.book contents:

    # Run this request 1 time
    myproj/auth.pi
    # Run this request 100 times
    myproj/api_get.pi * 100

Tests shall be run in the order declared in the playbook. Each test may be followed by a number indicating the number of times it shall be performed.

Running the playbook:

    sapt -b=myplay.book

Playbooks resolves paths relative to its own location.

Output:

    1/5: myproj/auth.pi                                         : OK (HTTP 200 - OK)
    time: 256ms
    2/5: myproj/api_get.pi                                      : OK (HTTP 200 - OK)
    100 iterations. 100 OK, 0 Error
    time: 1050ms/100 iterations [83ms-215ms] avg:105ms
    ------------------
    2/2 OK
    ------------------


Build:
------------
The tool is written in [zig](https://ziglang.org/), and depends on [libcurl](https://curl.se/libcurl/).

Prerequisites:
* [zig is installed](https://ziglang.org/download/) and available in path
* [libcurl is installed](https://curl.se/download.html) and library and headers are available in either path or through pkg-config.

Get source:

    git clone https://github.com/michaelo/sapt
    cd sapt


Development build/run:

    zig build run

Install:

    zig build install --prefix-exe-dir /usr/local/bin

*... or other path to put the executable to be in path.*


Design goals:
------------
* Only you should own and control your data - e.g. any version control and data sharing is up to you.
* Tests should be easily written and arranged - no hidden headers or such
* Support easy use of secrets and common variables/definitions
* Tests should live alongside the artifacts they tests


Terminology:
------

<table>
    <thead>
        <tr>
        <th>Term</th>
        <th>Description</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td>test</td>
            <td>the particular file/request to be processed. A test can result in "OK" or "ERROR"</td>
        </tr>
        <tr>
            <td>playbook</td>
            <td>a particular recipe of tests, their order and other parameters to be executed in a particular fashion</td>
        </tr>
    </tobdy>
</table>

Limitations:
------
Due in part to the efforts to both having a clear understanding of the RAM-usage, as well as keeping the heap-usage low and controlled, a set of discrete limitations are currently cheracteristic for the tool. I will very likely revise a lot of these decisions going forward - but here they are:

<table>
    <thead>
        <tr>
            <th>What</th>
            <th>Limitation</th>
        </tr>
    </thead>
    <tbody>
        <tr>
            <td colspan="2">General limitations</td>
        </tr>
        <tr>
            <td>Max number of tests to process in a given run</td>
            <td>128</td>
        </tr>
        <tr>
            <td>Max length for any file path</td>
            <td>1024</td>
        </tr>
        <tr>
            <td>Max repeats for single test</td>
            <td>1000</td>
        </tr>
        <tr>
            <td colspan="2">Test-specific parameters</td>
        </tr>
        <tr>
            <td>Max number of headers</td>
            <td>32</td>
        </tr>
        <tr>
            <td>Max length for a given HTTP-header</td>
            <td>8K</td>
        </tr>
        <tr>
            <td>Max number of variables+functions in a given test</td>
            <td>64</td>
        </tr>
        <tr>
            <td>Max length of a function response</td>
            <td>1024</td>
        </tr>
        <tr>
            <td>Max length of a variable key</td>
            <td>128</td>
        </tr>
        <tr>
            <td>Max length of a variable value</td>
            <td>8K</td>
        </tr>
        <tr>
            <td>Max URL length</td>
            <td>2048</td>
        </tr>
        <tr>
            <td>Max size of payload</td>
            <td>1M</td>
        </tr>
    </tbody> 
</table>



Test-file specification:
--------

    <input section>
    <optional set of headers>
    <optional payload section>
    <response section>
    <optional set of variable extraction expressions>

Comments:

    # Comment - must be start of line. Can be used everywhere except of in payload-section

Variables:

    {{my_var}}

Functions:

Convenience-functions are (to be) implemented. The argument can consist of other variables.

    {{base64enc(string)}}

Example:

    Authorization: basic {{base64enc({{username}}:{{password}})}}

Supported functions:

* base64enc(string)
* *TODO: urlencode(string)*
* *TODO: base64dec(string) ?*

Input section:

    # '>' marks start of 'input'-section, followed by HTTP verb and URL
    > POST https://some.where/
    # List of HTTP-headers, optional
    Content-Type: application/json
    Accept: application/json

Payload section, optional:

    # '-' marks start of payload-section, and it goes until output-section
    -
    {"some":"data}

*TBD: Implement support for injecting files?*

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

*TBD: Might support more regex-like expressions to control e.g. character groups and such.*


Must fix to be usable AKA pri-TODO:
-------------
* Implement support for automatically include .env-files if they are found, scoped to the folder in which the reside.
* Determine if current solution where variables can't be overwritten is a good idea or not.

TODO, somewhat ordered:
------------
* Set up automatic builds/cross-builds for Win10 x64, Linux x64, macOS (x64 and Arm)
    * TBD: shall we provide libcurl? If so, make sure to conform to https://curl.se/docs/copyright.html.
* Due to this being an explorative project while learning Zig, there are inconsistencies regarding memory-handling. This must be cleaned up and unified.
* Code quality - especially in main.zig - is quite crap at this point.
* Arguments: Revise names for all arguments. E.g. -f is now "format", while it's commonly assumed to be "force".
* sapt -h should also provide information about format of test files, and perhaps also playbooks, to be self-contained.
    * Propose:
        * sapt -h test
        * sapt -h playbook
* Provide better stats for repeats. We currently have min, max and avg/mean time. Could median or something mode-like be as useful or more? A plot would be nice here.  
* Add argument to abort on first error? E.g. if auth fails, there's no need to continue with the regular requests.
* TBD: Allow support for OS-environment variables. Control access by flag?
* Implement support to do step-by-step tests by e.g. requiring user to press enter between each test
* Provide better granularity for verbosity: e.g. separate between curl-verbose and sapt-verbose
* Playbooks:
    * TBD: What shall the semantics be regarding response data and variable-extraction when we have multiple repetitions? Makes no sense perhaps, so either have "last result matters", "undefined behaviour" or "unsupported". Wait for proper use cases.
    * Support repeating sequence of actions? E.g. add, check, remove.
        
            # Proposal of such functionality:
            group {
            # Include a couple tests
            @test1.pi
            @test2.pi

            # Perhaps also an in-playbook test?
            > GET https://example.com/
            < 200
            } * 1000
            #TBD: Must ensure parsing doesn't get confused with '}' inside headers, payload, er extraction-expressions.
            This smells like feature creep, so will wait for a proper use case before considering.

    * TBD: The current time of request - are we sure we're testing the correct segment?
* Test/verify safety of string lengths: parsing + how we add 0 for c-interop
* Support both keeping variables between (default) as well as explicitly allowing sandboxing (flag) of tests
* TBD: Shall we support "repeats" in test-files as well? Not only playbooks.
* Support HTTP follow?
* Actively limit the set of protocols we allow?
* Finish basic syntax highligh ruleset for the test-files
* Dev: Test feature flags based on comptime-parsing a feature-file


Feature-exploration AKA Maybe-TODO:
-------------
* Support handling encrypted variables?
* Support list of curl-commands as alternative output?
* Performant, light-weight GUI (optional)? Plotting performance for stress tests and such.
* Support response-time as test-prereq? Perhaps in playlist (low pri)
* TBD: Possibility to set "verbose" only for a specific test? Using e.g. the test-sequence-number?


Thanks / attributions:
--------
* zig - an interesting language of which this project is my first deliverable
* libcurl - the workhorse
