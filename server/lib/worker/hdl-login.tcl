api-handler post {/login} no {
	login 1
	pass 1
    } {

    global conf
    global env

    # XXX
    if {[info exists env(REMOTE_ADDR]} then {
	set srcaddr $env(REMOTE_ADDR)
    } else {
	set srcaddr "::1"
    }

    set am [::config get "authmethod"]

    clean-authfail ::dbdns

    set delay [check-failed-delay ::dbdns "ip" $srcaddr]
    if {$delay > 0} then {
	set delay [update-authfail ::dbdns "ip" $srcaddr]
	::scgi::serror 429 [mc {IP address '%1$s' temporarily blocked. Retry in %2$d seconds} $srcaddr $delay]
    }

    if {! [check-login $login]} then {
	::scgi::serror 403 [mc "Invalid login (%s)" $login]
    }

    set delay [check-failed-delay ::dbdns "login" $login]
    if {$delay > 0} then {
	set delay [update-authfail-both ::dbdns $srcaddr $login]
	::scgi::serror 429 [mc {Login '%1$s' temporarily blocked. Retry in %2$d secondes} $login $delay]
    }

    set ok [check-password ::dbdns $login $pass]
    switch $ok {
	-1 {
	    # system error
	    ::scgi::serror 500 [mc "Login failed due to an internal error"]
	}
	0 {
	    # login unsuccessful
	    set delay [update-authfail-both ::dbdns $srcaddr $login]
	    if {$delay <= 0} then {
		::scgi::serror 403 [mc "Login failed"]
	    } else {
		::scgi::serror 403 [mc "Login failed. Please retry in %d seconds" $delay]
	    }
	}
	1 {
	    # login successful
	    set casticket ""
	    set msg [register-user-login ::dbdns $login $casticket]
	    if {$msg ne ""} then {
		::scgi::serror 500 $msg
	    }
	    reset-authfail ::dbdns "ip"    $srcaddr
	    reset-authfail ::dbdns "login" $login
	}
    }

#     # XXXX
#    if {$am eq "casldap"} then {
#	::webapp::redirect "start"
#	exit 0
#    }

    ::scgi::set-header Content-Type text/plain
    ::scgi::set-body [mc "Login successful"]
}

##############################################################################
# Utility functions
##############################################################################

#
# Check user password against the crypted password stored in database
# and returns:
# - -1 if a system error occurred (msg sent via stderr in Apache log)
# - 0 if login was not successful
# - 1 if login was successful
#

proc check-password {dbfd login upw} {
    set success 0

    set am [::config get "authmethod"]
    switch $am {
	pgsql {
	    set qlogin [pg_quote $login]
	    set sql "SELECT password FROM pgauth.user WHERE login = $qlogin"
	    set dbpw ""
	    $dbfd exec $sql tab {
		set dbpw $tab(password)
	    }

	    if {[regexp {^\$1\$([^\$]+)\$} $dbpw dummy salt]} then {
		set crypted [::md5crypt::md5crypt $upw $salt]
		if {$crypted eq $dbpw} then {
		    set success 1
		}
	    }
	}
	ldap {
	    set url       [::config get "ldapurl"]
	    set binddn    [::config get "ldapbinddn"]
	    set bindpw    [::config get "ldapbindpw"]
	    set basedn    [::config get "ldapbasedn"]
	    set searchuid [::config get "ldapsearchlogin"]

	    set handle [::ldapx::ldap create %AUTO%]
	    if {[$handle connect $url $binddn $bindpw]} then {
		set filter [format $searchuid $login]

		set e [::ldapx::entry create %AUTO%]
		if {[catch {set n [$handle read $basedn $filter $e]} m]} then {
		    puts stderr "LDAP search for $login: $m"
		    return -1
		}
		$handle destroy

		switch $n {
		    0 {
			# no login found: success variable is already 0
		    }
		    1 {
			set userdn [$e dn]

			set handle [::ldapx::ldap create %AUTO%]
			if {[$handle connect $url $userdn $upw]} then {
			    set success 1
			}
			$handle destroy
		    }
		    default {
			# more than one login found
			puts stderr "More than one login found for '$login'. Check the ldapbasedn or ldapsearchlogin parameters."
			set success -1
		    }
		}

		$e destroy
	    } else {
		puts stderr "Cannot bind to ldap server: [$handle error]"
		$handle destroy
		set success -1
	    }
	}
    }

    return $success
}

proc register-user-login {dbfd login casticket} {
    global env

    #
    # Search id for the login
    #

    set qlogin [pg_quote $login]
    set idcor -1
    set sql "SELECT idcor FROM global.nmuser
			WHERE login = $qlogin AND present = 1"
    $dbfd exec $sql tab {
	set idcor $tab(idcor)
    }
    if {$idcor == -1} then {
	return [mc "Login '%s' does not exist" $login]
    }

    #
    # Generates a unique (at a given time) token
    # In order to test if a generated token is already used, we search it
    # in the global.tmp template table (which gathers all utmp and wtmp
    # lines)
    #

    set toklen [::config get "authtoklen"]

    $dbfd lock {global.utmp} {
	set found true
	while {$found} {
	    set token [pg_quote [get-random $toklen]]
	    set sql "SELECT idcor FROM global.tmp WHERE token = $token"
	    set found false
	    $dbfd exec $sql tab {
		set found true
	    }
	}

	#
	# Register token in utmp table
	#

	set ip NULL
	# XXX
	if {[info exists env(REMOTE_ADDR)]} then {
	    set ip "'$env(REMOTE_ADDR)'"
	}
	set qcas NULL
	if {$casticket ne ""} then {
	    set qcas [pg_quote $casticket]
	}

	set sql "INSERT INTO global.utmp (idcor, token, casticket, ip)
		    VALUES ($idcor, $token, $qcas, $ip)"
	if {! [$dbfd exec $sql msg]} then {
	    $dbfd abort
	    return [mc "Cannot register user login (%s)" $msg]
	}
    }

    #
    # Log successful flogin
    #

    # XXXX
#    d writelog "auth" "login $login $token"

    #
    # Set session cookie
    #

    ::scgi::set-cookie "session" $token 0 "" "" 0 0

    return ""
}

##############################################################################
# Authentication failure management
##############################################################################

#
# Remove all failed authentications older than 1 day
#

proc clean-authfail {dbfd} {
    set sql "DELETE FROM global.authfail
		    WHERE lastfail < LOCALTIMESTAMP - INTERVAL '1 DAY'"
    if {! [$dbfd exec $sql msg]} then {
	puts stderr "Error in expiration of failed logins: $msg"
	# We don't exit with this error. In case the database is
	# failing, we will report another database error later
	# with an error message related to the action of the user.
    }
}

#
# Remove failed authentication entry (for login/ip) in case of successful login
#

proc reset-authfail {dbfd otype origin} {
    set qorigin [pg_quote $origin]
    set qtype   [pg_quote $otype]
    set sql "DELETE FROM global.authfail
		    WHERE otype = $qtype AND origin = $qorigin"
    if {! [$dbfd exec $sql msg]} then {
	puts stderr "Error in resetting failed $otype: $msg"
    }
}

#
# Update login/ip entry in case of failed login
# Returns delay until end of blocking period (<= 0 if no more blocking)
#

proc update-authfail {dbfd otype origin} {
    set failXthreshold1 [::config get "fail${otype}threshold1"]
    set failXthreshold2 [::config get "fail${otype}threshold2"]
    set failXdelay1     [::config get "fail${otype}delay1"]
    set failXdelay2     [::config get "fail${otype}delay2"]

    #
    # Start of critical section
    #

    $dbfd lock {global.authfail} {
	#
	# Get current status
	#

	set qorigin [pg_quote $origin]
	set qtype   [pg_quote $otype]
	set sql "SELECT nfail
			FROM global.authfail
			WHERE otype = $qtype AND origin = $qorigin"
	set nfail -1
	$dbfd exec $sql tab {
	    set nfail $tab(nfail)
	}

	#
	# Update current status according to various thresholds
	#

	if {$nfail == -1} then {
	    set sql "INSERT INTO global.authfail (origin, otype, nfail)
			VALUES ($qorigin, $qtype, 1)"
	} elseif {$nfail >= $failXthreshold2} then {
	    set sql "UPDATE global.authfail
			SET nfail = nfail+1,
			    lastfail = NOW (),
			    blockexpire = NOW() + '$failXdelay2 second'
			WHERE otype = $qtype AND origin = $qorigin"
	} elseif {$nfail >= $failXthreshold1} then {
	    set sql "UPDATE global.authfail
			SET nfail = nfail+1,
			    lastfail = NOW (),
			    blockexpire = NOW() + '$failXdelay1 second'
			WHERE otype = $qtype AND origin = $qorigin"
	} else {
	    set sql "UPDATE global.authfail
			SET nfail = nfail+1,
			    lastfail = NOW ()
			WHERE otype = $qtype AND origin = $qorigin"
	}

	if {! [$dbfd exec $sql]} then {
	    $dbfd abort
	}
    }

    #
    # Return delay until end of blocking
    #

    return [check-failed-delay $dbfd $otype $origin]
}

#
# In case of failed login attempt, ban both login and IP address
#

proc update-authfail-both {dbfd srcaddr login} {
    set d1 [update-authfail $dbfd "ip"    $srcaddr]
    set d2 [update-authfail $dbfd "login" $login]
    return [expr max($d1,$d2)]
}


#
# Delay until end of blocking period
#
# Input:
#   - dbfd: database handle
#   - otype: "ip" or "login"
#   - origin: IP address or login name
# Output:
#   - return value: delay (in seconds) until access is allowed
#	(or 0 if not blocked or negative value if access is allowed again)
#

proc check-failed-delay {dbfd otype origin} {
    set qorigin [pg_quote $origin]
    set qtype   [pg_quote $otype]
    set sql "SELECT EXTRACT (EPOCH FROM blockexpire - LOCALTIMESTAMP(0))
			AS delay
		FROM global.authfail
    		WHERE otype = $qtype AND origin = $qorigin
		    AND blockexpire IS NOT NULL"
    set delay 0
    $dbfd exec $sql tab {
	set delay $tab(delay)
    }
    return $delay
}

#
# Check login name validity
#
# Input:
#   - parameters:
#	- login : login name
# Output:
#   - return value: 1 (valid) or 0 (invalid)
#
# History
#   2015/05/07 : pda/jean : design
#

proc check-login {name} {
    return [expr ! [regexp {[()<>*]} $name]]
}


proc get-random {nbytes} {
    # XXX
    set dev [::lc get "random"]
    if {[catch {set fd [open $dev {RDONLY BINARY}]} msg]} then {
	#
	# Silently fall-back to a non cryptographically secure random
	# if /dev/random is not available
	#
	expr srand([clock clicks -microseconds])
	set r ""
	for {set i 0} {$i < $nbytes} {incr i} {
	    append r [binary format "c" [expr int(rand()*256)]]
	}
    } else {
	#
	# Successful open: read random bytes
	#
	set r [read $fd $nbytes]
	close $fd
    }

    binary scan $r "H*" hex
    return $hex
}
