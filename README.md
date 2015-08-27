# athena

Next-Next-Gen Haskell.org automation?

Try this:

```
$ nix-shell --pure
$ cat > rackspace-creds.conf
RACKSPACE_LOGIN_USERNAME=<name>
RACKSPACE_LOGIN_APIKEY=<apikey>
^D
$ athena -c testing01
$ athena -c testing01
$ athena -l
```

Be careful. It's dangerous and written in bash script. Do not taunt
Happy Fun Ball.
