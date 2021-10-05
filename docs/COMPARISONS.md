Why a new tool AKA comparisons with existing products out there
==================================

The design goals of sapt:

* No remote communication whatsoever outside the actual tests
* Light weight
* Usable from command line
* No/negligeble startup-time
* Local ownership of data
* Easy to reproduce tests and test-suites
* Simple format for authoring tests. I.e. "hand craftable"

Some popular alternatives
--------------
* cURL
* Postman
* httpie
* Self-creafted bash-scripts with e.g. cURL, sed etc

You should probably check all of these out if you haven't already. They are all good.

### Differences from Postman:

* No heavy UI or such (Postman idles at >300MB RAM vs max observed with sapt so far: 17MB) 
* Postman is not usable from command line. You have newman, but it (AFAIK) requires you to first export the collections from Postman using their quite verbose .json-format
* It's not immidiately intuitive knowing what Postman stores at their servers and not
* Postman has lots of more features and among other things better response visualisation


### Differences from cURL:

* Disclaimer: sapt uses libcurl for the heavy lifting - much appreciated
* cURL has no built-in support for complete requests as a single piece of input, or combinations of such
* cURL has no built-in functions for evaluating responses or extracting segments of data from the results


### Differences from httpie:

* httpie is in many ways close to sapt - being command line based and quite streamlined. It is however still sentered around one command == one request (no notion of test-sets/suites)
* httpie has lots of other convenient functions which is considered out of scope for sapt


### Differences from self-creafted bash-scripts with e.g. cURL, sed etc

* This is probably the closest competitor to sapt
* sapt mostly formalizes this approach and makes it OS/shell-agnostic

