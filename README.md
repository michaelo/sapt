sapt - Simple API testing tool
==============

A simple tool to counter e.g. Postman.

Usage: Basic
-------------
    
testsuite/01-mytest.pi contents:
    
    > GET https://api.warnme.no/api/status
    < 200

Running the test:

    % sapt testsuite/01-mytest.pi
    1/1 testsuite/01-mytest.pi                                : OK

Help:

    % sapt -h
    -- shows help


sapt can take multiple arguments, both files and folders. The entire input-set will be sorted alphanumerically, thus you can dictate the order of execution by making sure the names of the scripts reflects the order:

* suite/01-auth.pi
* suite/02-post-entry.pi
* suite/03-get-posted-entry.pi
* suite/04-delete-posted-entry.pi

*Note: playbooks will later provide a way to override this.*

Usage: Complex:
----------------

Assuming you first have to get an authorization code from an auth-endpoint, which you will need in other tests.

Assuming the following files:

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

Assuming that the auth-endpoint will return something like this:

    {"access_token": "...", "id_token"="", "...", ...}

... the test will then set the id_token-variable, allowing it to be referred in subsequent tests.

*TODO: Implement support for automatically include .env-files if they are found, scoped to the folder in which the reside.*


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

Usage: playbook (draft, not implemented)
-----------
myplay.book contents:

    myproj/auth.pi 1
    myproj/api_get.pi 100 # Run this request 100 times

Tests shall be run in the order declared in the playbook. Each test may be followed by a number indicating the number of times it shall be performed.

Running the playbook:

    sapt -b=myplay.book

(TBD: base-point for relative paths in the playbook)

Output:

        Test             |       time             |    OK vs total
    1: myproj/auth.pi    | avg: 0.2s [0.1-0.3s]   |     1/1    OK
    2: myproj/api_get.pi | avg: 0.15s [0.1-0.5s]  |     95/100 ERROR


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
* Support "playbook"-files to define e.g. order and repetitions?
    * Playblooks shall also support setting variables
* Support both keeping variables between (default) as well as explicitly allowing sandboxing (flag) of tests
* Support parallel requests? Both for general perceived performance as well as for stress-tests (low pri)
* Support response-time as test-prereq? Perhaps in playlist (low pri)
* Test/verify safety of string lengths: parsing + how we add 0 for c-interop
* Support list of curl-commands as alternative output?
* TBD: Possibility to set "verbose" only for a specific test? Using e.g. the test-sequence-number?
* Support handling encrypted variables?
* Support/use coloring for improved output
* Support HTTP follow?

Later:
------
* Performant, light-weight GUI (optional)? Plotting performance for stress tests and such.
* Test feature flags based on comptime-parsing a feature-file

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
            <td>the particular file to be performed. A test can result in "OK" or "ERROR"</td>
        </tr>
        <tr>
            <td>playbook</td>
            <td>a particular recipe of tests, their order and other parameters to be executed in a particular fashion</td>
        </tr>
    </tobdy>
</table>

Limitations:
------
Due in part to the effort to avoid heap-usage, a set of discrete limitations are currently cheracteristic for the tool. I will very likely revise a lot of these decisions going forward - but here they are:

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

*TODO: Might support more regex-like expressions to control e.g. character groups and such.*


Thanks / attributions:
--------
* libcurl - the workhorse
* zig - an interesting language of which this project is my first deliverable


