implement Httpd;

include "sys.m";
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "daytime.m";
include "env.m";
include "string.m";
include "exception.m";
include "keyring.m";
include "security.m";
include "encoding.m";
include "sh.m";
include "ip.m";
include "attrdb.m";
include "regex.m";
include "mhttp.m";

sys: Sys;
daytime: Daytime;
env: Env;
exc: Exception;
keyring: Keyring;
random: Random;
str: String;
base64: Encoding;
sh: Sh;
ipm: IP;
attrdb: Attrdb;
regex: Regex;
http: Http;

print, sprint, fprint, fildes: import sys;
Url, Req, Resp, Hdrs, HTTP_10, HTTP_11, encodepath: import http;
OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE, CONNECT: import http;
prefix: import str;
IPaddr: import ipm;
Db, Dbentry, Tuples: import attrdb;
Re: import regex;

Version: con "nhttpd/0";


Repl: adt {
	re:	Re;
	rule:	list of ref (string, int);	# string, replacement index for regex
	maxrepl:	int;	# highest index for replacement

	parse:	fn(restr, rulestr: string): (ref Repl, string);
	apply:	fn(r: self ref Repl, s: string): (int, string, string);
};

# configs, one cfg per host/port pair
Cfgs: adt {
	file:	string;
	db:	ref Db;
	default:	ref Cfg;
	configs:	list of (string, string, ref Cfg);
	getch:	chan of (string, string, chan of (ref Cfg, string));

	init:	fn(file: string): (ref Cfgs, string);
	get:	fn(c: self ref Cfgs, host, port: string): (ref Cfg, string);
};

# config for a single host/port pair
Cfg: adt {
	host, port:	string;
	listings, cachesecs:	int;
	addrs:	list of ref (string, string);	# ip, port
	cgipaths:	list of ref (string, string, int);	# path, cmd|addr, cgi|scgi
	indexfiles:	list of string;
	redirs:	list of ref Repl;
	auths:	list of ref (string, string, string);	# path, realm, base64 user:pass

	new:	fn(): ref Cfg;
};

cfgs: ref Cfgs;


# represents a connection and a request on it
Op: adt {
	id, now:	int;
	keepalive:	int;
	chunked:	int;
	length:		big;
	fd:	ref Sys->FD;
	b:	ref Bufio->Iobuf;
	rhost, rport, lhost, lport:	string;
	req:	ref Req;
	resp:	ref Resp;
	cfg:	ref Cfg;
};

cgitimeoutsecs: con 3*60;

debugflag, vhostflag: int;
defaddr := "net!*!8000";
addrs: list of string;
webroot := "";
credempty: string;
ctlchan := "";

environment: list of (string, string);

Httpd: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

types := array[] of {
	(".pdf",	"application/pdf"),
	(".html",	"text/html; charset=utf-8"),
	(".htm",	"text/html; charset=utf-8"),
	(".txt",	"text/plain; charset=utf-8"),
	(".diff",	"text/plain; charset=utf-8"),
	(".patch",	"text/plain; charset=utf-8"),
	(".ps",		"application/postscript"),
	(".torrent",	"application/x-bittorrent"),
	(".dvi",	"application/x-dvi"),
	(".tar.gz",	"application/x-tgz"),
	(".tgz",	"application/x-tgz"),
	(".gz",		"application/x-gzip"),
	(".tar",	"application/x-tar"),
	(".mp3",	"audio/mpeg"),
	(".ogg",	"application/ogg"),
	(".jpg",	"image/jpeg"),
	(".gif",	"image/gif"),
	(".png",	"image/png"),
	(".css",	"text/css"),
	(".js",		"text/javascript; charset=utf-8"),
	(".c",		"text/plain; charset=utf-8"),
	(".b",		"text/plain; charset=utf-8"),
	(".h",		"text/plain; charset=utf-8"),
	(".sh",		"text/plain; charset=utf-8"),
	(".orig",	"text/plain; charset=utf-8"),
	(".conf",	"text/plain; charset=utf-8"),
	(".avi",	"video/x-msvideo"),
	(".bz2",	"application/x-bzip"),
	(".tex",	"text/plain; charset=utf-8"),
	(".mp4",	"video/mp4"),
	(".mpg",	"video/mpeg"),
};

Eok:			con 200;
Emovedpermanently:	con 301;
Enotmodified:		con 304;
Ebadrequest:		con 400;
Eunauthorized:		con 401;
Enotfound:		con 404;
Emethodnotallowed:	con 405;
Elengthrequired:	con 411;
Epreconditionfailed:	con 412;
Ebadmediatype:		con 415;
Enotsatisfiable:	con 416;
Eexpectationfailed:	con 417;
Eservererror:		con 500;
Enotimplemented:	con 501;
Ebadversion:		con 505;

statusmsgs := array[] of {
	(100,		"Continue"),
	(200,		"OK"),
	(206,		"Partial Content"),
	(301,		"Moved Permanently"),
	(304,		"Not Modified"),
	(400,		"Bad Request"),
	(401,		"Unauthorized"),
	(403,		"Forbidden"),
	(404,		"Object Not Found"),
	(405,		"Method Not Allowed"),
	(411,		"Length Required"),
	(412,		"Precondition Failed"),
	(415,		"Unsupported Media Type"),
	(416,		"Requested Range Not Satisfiable"),
	(417,		"Expectation Failed"),
	(500,		"Internal Server Error"),
	(501,		"Not Implemented"),
	(505,		"HTTP Version Not Supported"),
};

# relevant known request headers whose values are not allowed to be concatenated (not a full bnf #-rule)
nomergeheaders := array[] of {
	# these two would be useful to merge.  alas, it is not allowed by rfc2616, section 4.2, last paragraph
	"if-match",
	"if-none-match",

	"authorization",
	"content-length",
	"content-type",
	"host",
	"if-modified-since",
	"if-range",
	"if-unmodified-since",
	"range",
};

idch: chan of int;
randch: chan of int;
killch: chan of int;
killschedch: chan of (int, int, chan of int);
excch: chan of (int, chan of string);

timefd: ref Sys->FD;
errorfd: ref Sys->FD;
accessfd: ref Sys->FD;

Cgi, Scgi: con iota;
cgitypes := array[] of {"cgi", "scgi"};

cgispawnch: chan of (string, string, string, ref Req, ref Op, big, chan of (ref Sys->FD, ref Sys->FD, string));
scgidialch: chan of (string, chan of (ref Sys->FD, string));

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	env = load Env Env->PATH;
	daytime = load Daytime Daytime->PATH;
	keyring = load Keyring Keyring->PATH;
	exc = load Exception Exception->PATH;
	random = load Random Random->PATH;
	str = load String String->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
	sh = load Sh Sh->PATH;
	ipm = load IP IP->PATH;
	ipm->init();
	attrdb = load Attrdb Attrdb->PATH;
	err := attrdb->init();
	if(err != nil)
		fail("loading attrdb: "+err);
	regex = load Regex Regex->PATH;
	http = load Http Http->PATH;
	http->init(bufio);

	(cfgs, err) = Cfgs.init("/dev/null");
	if(err != nil)
		fail("making empty config: "+err);
	defcfg := cfgs.default = Cfg.new();

	arg->init(args);
	arg->setusage(arg->progname()+" [-dhl] [-A path realm user:pass] [-C cachesecs] [-a addr] [-c path command] [-f chanfile] [-i indexfile] [-n config] [-r orig new] [-s path addr] [-t extention mimetype] webroot");
	while((c := arg->opt()) != 0)
		case c {
		'A' =>	defcfg.auths = ref (arg->earg(), arg->earg(), base64->enc(array of byte arg->earg()))::defcfg.auths;
		'C' =>	defcfg.cachesecs = int arg->earg();
		'a' =>	addrs = arg->earg()::addrs;
		'c' =>	defcfg.cgipaths = ref (arg->earg(), arg->earg(), Cgi)::defcfg.cgipaths;
		'd' =>	debugflag++;
		'f' =>	ctlchan = arg->earg();
		'h' =>	vhostflag++;
		'i' =>	defcfg.indexfiles = arg->earg()::defcfg.indexfiles;
		'l' =>	defcfg.listings++;
		'n' =>
			file := arg->earg();
			(cfgs, err) = Cfgs.init(file);
			if(err != nil) {
				fprint(fildes(2), "reading %q: %s\n", file, err);
				raise "fail:usage";
			}
			defcfg.addrs = rev(defcfg.addrs);
			defcfg.cgipaths = rev(defcfg.cgipaths);
			defcfg.indexfiles = rev(defcfg.indexfiles);
			defcfg.redirs = rev(defcfg.redirs);
			defcfg.auths = rev(defcfg.auths);
		'r' =>
			(restr, rulestr) := (arg->earg(), arg->earg());
			(repl, rerr) := Repl.parse(restr, rulestr);
			if(err != nil) {
				fprint(fildes(2), "parsing redir %q %q: %s\n", restr, rulestr, rerr);
				raise "fail:usage";
			}
			defcfg.redirs = repl::defcfg.redirs;
		's' =>	defcfg.cgipaths = ref (arg->earg(), arg->earg(), Scgi)::defcfg.cgipaths;
		't' =>	(extension, mimetype) := (arg->earg(), arg->earg());
			ntypes := array[len types+1] of (string, string);
			ntypes[0] = (extension, mimetype);
			ntypes[1:] = types;
			types = ntypes;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	webroot = hd args;
	defcfg.addrs = rev(defcfg.addrs);
	defcfg.cgipaths = rev(defcfg.cgipaths);
	defcfg.indexfiles = rev(defcfg.indexfiles);
	defcfg.redirs = rev(defcfg.redirs);
	defcfg.auths = rev(defcfg.auths);
	credempty = base64->enc(array of byte ":");

	environment = env->getall();

	if(ctlchan != nil) {
		fileio := sys->file2chan("/chan", ctlchan);
		if(fileio == nil)
			fail(sprint("file2chan in /chan: %q: %r", ctlchan));
		spawn ctlhandler(fileio);
	}

	sys->pctl(Sys->FORKNS|Sys->FORKENV|Sys->FORKFD, nil);
	if(sys->chdir(webroot) != 0)
		fail(sprint("chdir webroot %s: %r", webroot));

	timefd = sys->open("/dev/time", Sys->OREAD);
	if(timefd == nil)
		fail(sprint("open /dev/time: %r"));

	errorfd = sys->open("/services/logs/httpderror", Sys->OWRITE);
	accessfd = sys->open("/services/logs/httpdaccess", Sys->OWRITE);
	if(errorfd != nil)
		sys->seek(errorfd, big 0, Sys->SEEKEND);
	if(accessfd != nil)
		sys->seek(accessfd, big 0, Sys->SEEKEND);

	idch = chan[8] of int;
	spawn idgen();
	randch = chan of int;
	spawn randgen();
	killch = chan of int;
	killschedch = chan of (int, int, chan of int);
	spawn killer();
	excch = chan of (int, chan of string);
	spawn exceptsetter();

	cgispawnch = chan of (string, string, string, ref Req, ref Op, big, chan of (ref Sys->FD, ref Sys->FD, string));
	spawn cgispawner();

	scgidialch = chan of (string, chan of (ref Sys->FD, string));
	spawn scgidialer();

	if(addrs == nil)
		addrs = defaddr::nil;
	for(addrs = rev(addrs); addrs != nil; addrs = tl addrs)
		spawn announce(hd addrs);
}

announce(addr: string)
{
	(aok, aconn) := sys->announce(addr);
	if(aok != 0)
		fail(sprint("announce %s: %r", addr));
	say("announed to "+addr);
	for(;;) {
		(lok, lconn) := sys->listen(aconn);
		if(lok != 0)
			fail(sprint("listen %s: %r", addr));
		dfd := sys->open(lconn.dir+"/data", Sys->ORDWR);
		if(dfd != nil)
			spawn httpserve(dfd, lconn.dir);
		else
			say(sprint("opening data file: %r"));
		lconn.dfd = nil;
	}
}

idgen()
{
	id := 0;
	for(;;)
		idch <-= id++;
}

randgen()
{
	for(;;)
		randch <-= random->randomint(Random->NotQuiteRandom);
}

killer()
{
	for(;;)
	alt {
	pid := <-killch =>
		kill(pid);
	(pid, timeout, respch) := <-killschedch =>
		spawn timeoutkill(pid, timeout, respch);
	}
}

timeoutkill(pid, timeout: int, respch: chan of int)
{
	respch <-= sys->pctl(0, nil);
	sys->sleep(timeout);
	kill(pid);
}

exceptsetter()
{
	for(;;) {
		(pid, respch) := <-excch;
		err: string;
		fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE);
		if(fd == nil || fprint(fd, "exceptions notifyleader") == -1)
			err = sprint("setting exception handling for pid %d: %r", pid);
		if(respch == nil && err != nil)
			fail("exceptsetter: "+err);
		if(respch != nil)
			respch <-= err;
	}
}

cgispawner()
{
	for(;;) {
		(cmd, path, cgipath, req, op, length, replych) := <-cgispawnch;
		spawn cgispawn(cmd, path, cgipath, req, op, length, replych);
	}
}

cgispawn(cmd, path, cgipath: string, req: ref Req, op: ref Op, length: big, replych: chan of (ref Sys->FD, ref Sys->FD, string))
{
	fd0 := array[2] of ref Sys->FD;
	fd1 := array[2] of ref Sys->FD;
	fd2 := array[2] of ref Sys->FD;
	if(sys->pipe(fd0) != 0 || sys->pipe(fd1) != 0 || sys->pipe(fd2) != 0) {
		replych <-= (nil, nil, sprint("pipe: %r"));
		return;
	}
	spawn errlogger(fd2[0]);

	if(sys->pctl(Sys->NEWFD|Sys->FORKNS|Sys->FORKENV, fd0[1].fd::fd1[1].fd::fd2[1].fd::nil) < 0) {
		replych <-= (nil, nil, sprint("pctl newfd: %r"));
		return;
	}
	for(l := cgivars(path, cgipath, req, op, length, nil); l != nil; l = tl l)
		env->setenv((hd l).t0, (hd l).t1);

	if(sys->dup(fd0[1].fd, 0) == -1 || sys->dup(fd1[1].fd, 1) == -1 || sys->dup(fd2[1].fd, 2) == -1) {
		replych <-= (nil, nil, sprint("dup: %r"));
		return;
	}
	replych <-= (fd0[0], fd1[0], nil);
	fd0 = fd1 = fd2 = nil;
	err := sh->system(nil, cmd);
	if(err != nil)
		say(sprint("cgispawn, cmd %q: %s", cmd, err));
}

errlogger(fd: ref Sys->FD)
{
	for(;;) {
		n := sys->read(fd, d := array[Sys->ATOMICIO] of byte, len d);
		if(n < 0)
			die(-1, sprint("reading stderr: %r"));
		if(n == 0)
			break;
		say(string d[:n]);
	}
}

scgidialer()
{
	for(;;) {
		(scgiaddr, replychan) := <-scgidialch;
		spawn scgidial(scgiaddr, replychan);
	}
}

scgidial(scgiaddr: string, replychan: chan of (ref Sys->FD, string))
{
	(ok, conn) := sys->dial(scgiaddr, nil);
	if(ok < 0) {
		say(sprint("dialing scgid %s: %r", scgiaddr));
		replychan <-= (nil, "dialing scgid failed");
	} else
		replychan <-= (conn.dfd, nil);
}

ctlhandler(fio: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <- fio.read =>
		if(rc == nil)
			continue;
		rc <-= (nil, "permission denied");

        (nil, data, nil, wc) := <- fio.write =>
                if(wc == nil)
                        continue;
		s := string data;
		if(s != nil && s[len s-1] == '\n')
			s = s[:len s-1];
		case s {
		"reload" =>
			say("reloading db");
			if(cfgs.db.reopen() != 0) {
				msg := sprint("reopening config files: %r");
				say(msg);
				wc <-= (0, msg);
				continue;
			}
			err := cfgsread(cfgs);
			if(err != nil) {
				msg := "error reloading config, keeping current: "+err;
				say(msg);
				wc <-= (0, msg);
				continue;
			}
			wc <-= (len data, nil);
		* =>
			wc <-= (0, sprint("bad command: %q", s));
		}
	}
}

httpserve(fd: ref Sys->FD, conndir: string)
{
	id := <-idch;
	chat(id, "httpserve");

	(lhost, lport) := readaddr(id, conndir+"/local");
	(rhost, rport) := readaddr(id, conndir+"/remote");
	chat(id, sprint("connect from %s:%s to %s:%s", rhost, rport, lhost, lport));

	pid := sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->NODEVS, nil);
	excch <-= (pid, nil);
	if(sys->bind(webroot,  "/", Sys->MREPL) < 0)
		die(id, sprint("bind %q /: %r", webroot));

	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		die(id, sprint("bufio open: %r"));

	op := ref Op(id, 0, 0, 0, big 0, fd, b, rhost, rport, lhost, lport, nil, nil, nil);

	for(nsrvs := 0; ; nsrvs++) {
		if(nsrvs > 0 && !op.keepalive)
			break;

		if(sys->chdir("/") != 0)
			break;

		op.chunked = op.keepalive = 0;
		op.length = big -1;
		httptransact(pid, b, op);
	}
}

httptransact(pid: int, b: ref Iobuf, op: ref Op)
{
	id := op.now;
	op.now = readtime();
	hdrs := Hdrs.new(("server", Version)::nil);

	killschedch <-= (pid, 3*60*1000, respch := chan of int);
	killpid := <-respch;

	(req, rerr) := Req.read(b);
	hdrs.add("date", httpdate(op.now));
	if(rerr != nil) {
		hdrs.add("connection", "close");
		op.resp = Resp.mk(HTTP_10, nil, nil, hdrs);
		responderrmsg(op, Ebadrequest, "Bad Request: parsing message: "+rerr);
		killch <-= killpid;
		die(id, "reading request: "+rerr);
	}
	if(req.major != 1) {
		hdrs.add("connection", "close");
		op.resp = Resp.mk(HTTP_10, nil, nil, hdrs);
		responderrmsg(op, Ebadversion, sprint("HTTP Version Not Supported: version requested is HTTP/%d.%d", req.major, req.minor));
		killch <-= killpid;
		die(id, sprint("unsupported http version, HTTP/%d.%d", req.major, req.minor));
	}
	killch <-= killpid;
	chat(id, sprint("request: method %q url %q version %q", http->methodstr(req.method), req.url.pack(), sprint("HTTP/%d.%d", req.major, req.minor)));
	op.req = req;

	# all values besides "close" are supposedly header names, not important
	(contoks, conerr) := tokenize(req.h.getlist("connection"));
	op.keepalive = req.version() >= HTTP_11 && conerr == nil && !listhas(listlower(contoks), "close");
	op.resp = resp := Resp.mk(req.version(), "200", "OK", hdrs);

	# tell client if it is sending ambiguous requests: duplicate headers of the important kind
	for(i := 0; i < len nomergeheaders; i++)
		if(len req.h.findall(nomergeheaders[i]) > 1)
			return responderrmsg(op, Ebadrequest, sprint("Bad Request: You sent duplicate headers for \"%s\"", nomergeheaders[i]));

	if(req.h.has("proxy-authorization", nil))
		return responderrmsg(op, Ebadrequest, "Bad Request: You or a proxy server sent Proxy-Authorization credentials");

	if(req.version() >= HTTP_11 && !req.h.has("host", nil))
		return responderrmsg(op, Ebadrequest, "Bad Request: Missing header \"Host\"");

	host := str->splitl(req.h.get("host"), ":").t0;
	(cfg, err) := cfgs.get(host, op.lport);
	if(err == "no config")
		return responderrmsg(op, Enotfound, nil);
	if(err != nil) {
		say("getting config: "+err);
		return responderrmsg(op, Eservererror, "Internal Server Error: Configuration not available");
	}

	# do not accept request when doing vhost and request is from ip that we shouldn't serve host:port on
	addrokay := !vhostflag || cfg.addrs == nil;
	if(!addrokay) {
		for(as := cfg.addrs; !addrokay && as != nil; as = tl as) {
			(chost, cport) := *(hd as);
			say(sprint("testing config host %q port %q against connection host %q port %q", chost, cport, op.lhost, op.lport));
			addrokay = chost == op.lhost && cport == op.lport;
		}
	}

	if(cfg == nil || !addrokay) {
		if(cfg == nil)
			chat(id, sprint("no config for host %q port %q", host, op.lport));
		else
			chat(id, "request on not allowed ip:port");
		return responderrmsg(op, Enotfound, nil);
	}
	op.cfg = cfg;

	case req.method {
	GET or HEAD or POST =>
		;
	TRACE =>
		hdrs.add("content-type", "message/http");
		return responderrmsg(op, Eok, req.pack());

	OPTIONS =>
		# xxx should be based on path
		hdrs.add("allow", "OPTIONS, GET, HEAD, POST, TRACE");
		hdrs.add("accept-ranges", "bytes");
		return responderrmsg(op, Eok, nil);

	PUT or DELETE =>
		# note: when implementing these, complete support for if-match and if-none-match, and much more probably
		return responderrmsg(op, Enotimplemented, "Not Implemented: PUT and DELETE are not supported");

	* =>
		return responderrmsg(op, Enotimplemented, "Unknown Method: "+http->methodstr(req.method));
	}

	path := pathsanitize(req.url.path);
	chat(id, "path is "+path);

	# we ignore the port in the host-header.  this is illegal according to rfc2616, but using it is just silly.
	# also, we violate rfc2616 by sending 404 "not found" when the host doesn't exist.
	# we should send 400 "bad request" then, but that is just silly too.
	(havehost, hostdir) := req.h.find("host");
	if(!havehost) {
		hostdir = "_default:"+cfg.port;
	} else {
		(hostdir, nil) = str->splitstrl(hostdir, ":");
		if(str->drop(hostdir, "0-9a-zA-Z.-") != nil || str->splitstrl(hostdir, "..").t1 != nil)
			return responderrmsg(op, Enotfound, nil);
		hostdir += ":"+cfg.port;
	}
	if(vhostflag && sys->chdir(hostdir) != 0) {
		hostdir = "_default:"+cfg.port;
		# according to the spec, this error should send a "bad request" response...
		if(havehost && sys->chdir(hostdir) != 0)
			return responderrmsg(op, Enotfound, nil);
	}

	haveauth := needauth := 0;
	realm: string;
	which, cred: string;
	(which, cred) = str->splitstrr(req.h.get("authorization"), " ");
	if(str->tolower(which) != "basic ")
		cred = nil;
	for(a := cfg.auths; !haveauth && a != nil; a = tl a) {
		(apath, arealm, acred) := *hd a;
		if(prefix(apath, path)) {
			needauth = 1;
			realm = arealm;
			haveauth = cred == acred;
		}
	}
	if(needauth && !haveauth) {
		resp.h.add("www-authenticate", sprint("Basic realm=\"%s\"", realm));	# xxx doublequote-quote realm?
		return responderrmsg(op, Eunauthorized, nil);
	}
	if(req.h.has("authorization", nil) && !needauth && cred != credempty) {
		resp.h.add("www-authenticate", sprint("Basic realm=\"authentication not allowed\""));
		return responderrmsg(op, Eunauthorized, "You sent authorization credentials which is not allowed by this resource.  Please use an empty username and password or do not send authorization credentials altogether.");
	}

	for(r := cfg.redirs; r != nil; r = tl r) {
		repl := hd r;
		(match, dest, replerr) := repl.apply(path);
		if(replerr != nil) {
			chat(id, "redirections misconfiguration: "+replerr);
			return responderrmsg(op, Eservererror, "An error occurred while handling a redirection");
		}
		if(!match)
			continue;
		resp.h.set("location", dest);	# xxx return absolute url?
		dest = htmlescape(dest);
		return responderrmsg(op, Emovedpermanently, sprint("Moved Permanently: moved to <a href=\"%s\">%s</a>", dest, dest));
	}

	# if path is cgi-handled, let cgi() handle the request
	if(((cgipath, cgiaction, cgitype) := findcgi(cfg, path)).t1 != nil) {
		timeo := cgitimeoutsecs*1000;
		donech := chan of int;
		spawn timeout(op, timeo, timeoch := chan of int, donech);
		timeopid := <- timeoch;
		spawn cgi(path, op, cgipath, cgiaction, cgitype, timeopid, timeoch, donech);
		<-donech;
		return;
	}

	# path is one of:  plain file, directory (either listing or plain index file)
	dfd := sys->open("."+path, Sys->OREAD);
	if(dfd != nil)
		(dok, dir) := sys->fstat(dfd);
	if(dir.mode&Sys->DMDIR && path[len path-1] == '/') {
		for(l := cfg.indexfiles; l != nil; l = tl l) {
			ipath := "."+path+hd l;
			(iok, idir) := sys->stat(ipath);
			if(iok != 0)
				continue;
			ifd := sys->open(ipath, Sys->OREAD);
			if(ifd == nil)
				return responderrmsg(op, Enotfound, nil);
			dfd = ifd;
			dok = iok;
			dir = idir;
			path += hd l;
			break;
		}
	}
	if(dfd == nil || dok != 0 || (dir.mode&Sys->DMDIR) && (!cfg.listings || path != nil && path[len path-1] != '/'))
		return responderrmsg(op, Enotfound, nil);

	if(req.method == POST) {
		resp.h.add("allow", "GET, HEAD, OPTIONS");
		return responderrmsg(op, Emethodnotallowed, "POST not allowed");
	}

	resp.h.add("last-modified", httpdate(dir.mtime));
	tag := etag(path, op, dir);
	resp.h.add("etag", tag);

	ifmatch := req.h.get("if-match");
	if(req.version() >= HTTP_11 && ifmatch != nil && !etagmatch(req.version(), tag, ifmatch, 1))
		return responderrmsg(op, Epreconditionfailed, sprint("Precondition Failed: etags %s, specified with If-Match did not match", htmlescape(ifmatch)));

	ifmodsince := parsehttpdate(req.h.get("if-modified-since"));
	chat(id, sprint("ifmodsince, %d, mtime %d", ifmodsince, dir.mtime));
	# http/1.0, head and if-modified-since: rfc1945#8.1;  unsupported date value can safely be ignored.
	if(!(req.version() == HTTP_10 && req.method == HEAD) && ifmodsince && dir.mtime <= ifmodsince)
		return responderr(op, Enotmodified);

	ifnonematch := req.h.get("if-none-match");
	if(req.version() >= HTTP_11 && ifnonematch != nil && req.method == GET && etagmatch(req.version(), tag, ifnonematch, 0))
		return responderr(op, Enotmodified);

	# unsupported date value causes a "precondition failed"
	ifunmodsince := parsehttpdate(ifunmodsincestr := req.h.get("if-unmodified-since"));
	chat(id, sprint("ifunmodsince, %d", ifunmodsince));
	if(req.version() >= HTTP_11 && (ifunmodsince && dir.mtime > ifunmodsince || ifunmodsincestr != nil && !ifunmodsince))
		return responderrmsg(op, Epreconditionfailed, sprint("Precondition Failed: object has been modified since %s", req.h.get("if-unmodified-since")));

	if(cfg.cachesecs)
		resp.h.add("cache-control", maxage(op.cfg, path));

	if(dir.mode & Sys->DMDIR)
		listdir(path, op, dfd);
	else
		plainfile(path, op, dfd, dir, tag);
}

plainfile(path: string, op: ref Op, dfd: ref Sys->FD, dir: Sys->Dir, tag: string)
{
	id := op.id;
	req := op.req;
	resp := op.resp;

	chat(id, "doing plain file");
	ct := gettype(path);
	resp.h.add("content-type", ct);
	op.length = dir.length;
	resp.h.add("content-length", string op.length);

	(valid, ranges) := parserange(req.version(), req.h.get("range"), dir);
	if(!valid) {
		resp.h.add("content-range", sprint("bytes */%bd", dir.length));
		return responderrmsg(op, Enotsatisfiable, nil);
	}
	bound := "";
	ifrange := req.h.get("if-range");
	# unsupported date value can safely be ignored.
	if(ranges != nil && (ifrange == nil
	                     || ifrange[0] == '"' && tag == ifrange
	                     || dir.mtime <= parsehttpdate(ifrange))) {
		if(len ranges == 1) {
			(start, end) := *hd ranges;
			resp.h.add("content-range", sprint("bytes %bd-%bd/%bd", start, end-big 1, dir.length));
		} else {
			bound = sha1(array of byte (string <-randch+","+string op.now));
			resp.h.set("content-type", "multipart/byteranges; boundary="+bound);
			op.chunked = resp.version() >= HTTP_11;
		}
		resp.st = "206";
		resp.stmsg = "partial content";
	} else
		ranges = ref (big 0, dir.length)::nil;

	accesslog(op);

	rerr := hresp(resp, op.fd, op.keepalive, op.chunked);
	if(rerr != nil)
		die(id, "writing response: "+rerr);

	if(req.method == HEAD)
		return;

	for(; ranges != nil; ranges = tl ranges) {
		(off, end) := *hd ranges;
		if(bound != nil)
			hwrite(op, array of byte sprint("--%s\r\ncontent-type: %s\r\ncontent-range: bytes %bd-%bd/%bd\r\n\r\n", bound, ct, off, end-big 1, dir.length));
		while(off < end) {
			want := int (end-off);
			if(want > Sys->ATOMICIO)
				want = Sys->ATOMICIO;
			n := sys->pread(dfd, d := array[want] of byte, len d, off);
			if(n < 0)
				die(id, sprint("reading file: %r"));
			if(n == 0)
				break;
			off += big n;
			hwrite(op, d[:n]);
		}
		if(bound != nil)
			hwrite(op, array of byte "\r\n");
	}
	hwriteeof(op);
}

listdir(path: string, op: ref Op, dfd: ref Sys->FD)
{
	id := op.id;
	resp := op.resp;

	chat(id, "doing directory listing");
	resp.h.add("content-type", "text/html; charset=utf-8");
	op.chunked = resp.version() >= HTTP_11;

	accesslog(op);

	rerr := hresp(resp, op.fd, op.keepalive, op.chunked);
	if(rerr != nil)
		die(id, "writing response: "+rerr);

	if(op.req.method == HEAD)
		return;

	begin := mkhtmlstart("listing for "+path) + sprint("<h1>listing for %s</h1><hr/><table><tr><th>last modified</th><th>size</th><th>name</th></tr>\n", pathurls(path));
	hwrite(op, array of byte begin);
	for(;;) {
		(nd, d) := sys->dirread(dfd);
		if(nd < 0)
			die(id, sprint("reading dir: %r"));
		if(nd == 0)
			break;
		html := "";
		for(i := 0; i < nd && i < len d; i++) {
			name := d[i].name;
			if(d[i].mode & Sys->DMDIR)
				name += "/";
			html += sprint("<tr><td class=\"mtime\">%s</td><td class=\"size\">%bd</td><td class=\"name\"><a href=\"%s\">%s</a></td></tr>\n", daytime->filet(op.now, d[i].mtime), d[i].length, htmlescape(encodepath(name)), htmlescape(name));
		}
		hwrite(op, array of byte html);
	}
	end := sprint("</table><hr/></body></html>\n");
	hwrite(op, array of byte end);
	hwriteeof(op);
}

timeout(op: ref Op, timeo: int, timeoch, donech: chan of int)
{
	timeoch <-= sys->pctl(Sys->NEWPGRP, nil);
	opid := <-timeoch;
	sys->sleep(timeo);
	chat(op.id, sprint("timeout %d ms for request, killing handler pid %d, timeopid %d", timeo, opid, sys->pctl(0, nil)));
	killch <-= opid;
	responderrmsg(op, Eservererror, "Response could not be generated in time.");
	donech <-= 0;
}

cgi(path: string, op: ref Op, cgipath, cgiaction: string, cgitype, timeopid: int, cgich, donech: chan of int)
{
	# set up new process group and exception propagation so
	# we always clean up nicely when one of the child procs dies.
	# we always have to respond on donech (or be killed by the timeout
	# proc) or we'll leave processes lingering
	npid := sys->pctl(Sys->NEWPGRP, nil);
	if(npid < 0) {
		killch <-= timeopid;
		chat(op.id, sprint("pctl newpgr: %r"));
		responderrmsg(op, Eservererror, nil);
		donech <-= 0;
		return;
	}
	excch <-= (npid, respch := chan of string);
	err := <-respch;
	if(err != nil) {
		killch <-= timeopid;
		chat(op.id, sprint("setting exception notify leader: %s", err));
		responderrmsg(op, Eservererror, nil);
	} else {
		# catch exceptions (e.g. when writing to remote fails), to make sure our caller can return
		{ _cgi(path, op, cgipath, cgiaction, cgitype, timeopid, cgich); }
		exception {
		* =>	killch <-= timeopid;	# may already be killed
		}
	}
	donech <-= 0;
}

_cgi(path: string, op: ref Op, cgipath, cgiaction: string, cgitype, timeopid: int, cgich: chan of int)
{
	cgich <-= sys->pctl(0, nil);

	id := op.id;
	req := op.req;
	resp := op.resp;

	# we are taking a short cut here to avoid feeding the bloat monster:  parsing transfer-coding is too involved for us.
	length := big 0;
	if(req.method == POST) {
		transferenc := req.h.getlist("transfer-encoding");
		if(req.version() >= HTTP_11 && transferenc != nil && transferenc != "identity")
			return responderrmsg(op, Enotimplemented, "Not Implemented: Transfer-Encodings other than identity (i.e. no transfer encoding) are not supported (note: Only single values in the simplest syntax are accepted)");

		if(req.h.has("content-length", nil)) {
			lengthstr := req.h.get("content-length");
			if(lengthstr == nil || str->drop(lengthstr, "0-9") != "")
				return responderrmsg(op, Ebadrequest, sprint("Bad Request: Invalid Content-Length: %q", lengthstr));
			length = big lengthstr;
		} else {
			e := Elengthrequired;
			emsg: string;
			if(req.version() == HTTP_10) {
				# rfc1945#7.2.2
				e = Ebadrequest;
				emsg = "Bad Request: Missing header Content-Length";
			}
			return responderrmsg(op, e, emsg);
		}

		contentenc := req.h.getlist("content-encoding");
		if(contentenc != nil && contentenc != "identity")
			return responderrmsg(op, Enotimplemented, "Not Implemented: Content-Encoding other than identity (i.e. no content encoding) are not supported (note: Only single values in the simplest syntax are accepted)");

		if(req.version() >= HTTP_11 && (expect := req.h.getlist("expect")) != nil) {
			# we are not compliant here, values such as "100-continue, " are valid and must be treated as "100-continue"
			# however, that is too much of a pain to parse (well, it gets much more complex, for no good reason).
			# tough luck sir bloat!
			if(str->tolower(expect) != "100-continue")
				return responderrmsg(op, Eexpectationfailed, sprint("Unrecognized Expectectation: %q (note: Only single values in the simplest syntax are accepted)", expect));
			fprint(op.fd, "HTTP/1.1 100 Continue\r\n\r\n");
		}

		chat(id, sprint("post, client content-length %bd", length));
	}

	chat(id, sprint("handling cgi request, cgipath %q cgiaction %q cgitype %s, pid %d timeopid %d", cgipath, cgiaction, cgitypes[cgitype], sys->pctl(0, nil), timeopid));

	fd0, fd1: ref Sys->FD;
	if(cgitype == Scgi) {
		scgidialch <-= (cgiaction, replychan := chan of (ref Sys->FD, string));
		(sfd, serr) := <-replychan;
		if(serr != nil)
			return responderrmsg(op, Eservererror, nil);

		sreq := scgirequest(path, cgipath, req, op, length);
		if(sys->write(sfd, sreq, len sreq) != len sreq) {
			chat(id, sprint("write scgi request: %r"));
			return responderrmsg(op, Eservererror, nil);
		}
		fd0 = fd1 = sfd;
	} else {
		err: string;
		cgispawnch <-= (cgiaction, path, cgipath, req, op, length, replych := chan of (ref Sys->FD, ref Sys->FD, string));
		(fd0, fd1, err) = <-replych;
		if(err != nil) {
			chat(id, "cgispawn: "+err);
			return responderrmsg(op, Eservererror, nil);
		}
	}

	if(length > big 0)
		spawn cgifunnel(op.b, fd0, length);

	sb := bufio->fopen(fd1, Bufio->OREAD);
	if(sb == nil) {
		chat(id, sprint("bufio fopen cgi fd: %r"));
		return responderrmsg(op, Eservererror, nil);
	}

	l := sb.gets('\n');
	killch <-= timeopid;
	if(!prefix("status:", str->tolower(l))) {
		chat(id, "bad cgi response line: "+l);
		return responderrmsg(op, Eservererror, "Internal Server Error:  Handler sent bad response line");
	}
	l = str->drop(l[len "status:":], " \t");
	(resp.st, resp.stmsg) = str->splitstrl(l, " ");
	if(resp.stmsg != nil)
		resp.stmsg = droptl(resp.stmsg[1:], " \t\r\n");
	if(len resp.st != 3 || str->drop(resp.st, "0-9") != "") {
		chat(id, "bad cgi response line: "+l);
		return responderrmsg(op, Eservererror, "Internal Server Error:  Handler sent bad response line");
	}

	(hdrs, rerr) := Hdrs.read(sb);
	if(rerr != nil) {
		chat(id, "reading cgi headers: "+rerr);
		return responderrmsg(op, Eservererror, "Internal Server Error:  Error reading headers from handler");
	}
	elength := big -1;
	if(hdrs.has("content-length", nil)) {
		elengthstr := hdrs.get("content-length");
		if(elengthstr == nil || str->drop(elengthstr, "0-9") != "") {
			chat(id, "bad cgi content-length header: "+elengthstr);
			return responderrmsg(op, Eservererror, "Internal Server Error:  Invalid content-length from handler");
		}
		op.length = elength = big elengthstr;
	}
	for(hl := hdrs.all(); hl != nil; hl = tl hl)
		resp.h.add((hd hl).t0, (hd hl).t1);

	accesslog(op);

	op.chunked = elength == big -1 && resp.version() >= HTTP_11;
	rerr = hresp(resp, op.fd, op.keepalive, op.chunked);
	if(rerr != nil) {
		chat(id, "writing response: "+rerr);
		return;
	}

	if(req.method == HEAD)
		return;

	for(;;) {
		n := sb.read(d := array[Sys->ATOMICIO] of byte, len d);
		if(n < 0)
			die(id, sprint("reading file: %r"));
		if(n == 0) {
			if(elength > big 0)
				die(id, "bad cgi body, message shorter than content-length specified");
			break;
		}
		if(elength > big 0) {
			if(big n > elength)
				die(id, "bad cgi body, message longer than content-length specified");
			elength -= big n;
		}
		hwrite(op, d[:n]);
	}
	hwriteeof(op);
	chat(id, "request done");
}

cgifunnel(b: ref Iobuf, sfd: ref Sys->FD, length: big)
{
	while(length > big 0) {
		need := Sys->ATOMICIO;
		if(big need > length)
			need = int length;
		n := b.read(d := array[need] of byte, len d);
		if(n < 0)
			fail(sprint("fail:cgi read: %r"));
		if(n == 0)
			fail(sprint("fail:cgi read: premature eof"));
		if(sys->write(sfd, d, n) != n)
			fail(sprint("fail:cgi write: %r"));
		length -= big n;
	}
}

hresp(resp: ref Resp, fd: ref Sys->FD, keepalive, chunked: int): string
{
	if(keepalive)
		resp.h.add("connection", "keep-alive");
	else
		resp.h.add("connection", "close");
	if(chunked) {
		resp.h.add("transfer-encoding", "chunked");
		resp.h.del("content-length", nil);
	}
	return resp.write(fd);
}

hwrite(op: ref Op, d: array of byte)
{
	if(len d == 0)
		return;

	if(op.chunked) {
		length := array of byte sprint("%x\r\n", len d);
		nd := array[len length+len d+2] of byte;
		nd[:] = length;
		nd[len length:] = d;
		nd[len length+len d:] = array of byte "\r\n";
		d = nd;
	}
	if(sys->write(op.fd, d, len d) != len d)
		fail(sprint("writing response data: %r"));
}

hwriteeof(op: ref Op)
{
	if(op.chunked)
		fprint(op.fd, "0\r\n\r\n");
}

respond(op: ref Op, st: int, errmsgstr: string, ct: string)
{
	resp := op.resp;
	resp.st = string st;
	resp.stmsg = statusmsg(st);
	if(ct != nil)
		resp.h.set("content-type", ct);

	op.chunked = 0;
	errmsg := array of byte errmsgstr;
	op.length = big len errmsg;
	if(!(st >= 100 && st < 200 || st == 204 || st == 304))
		resp.h.set("content-length", string op.length);

	err := hresp(resp, op.fd, op.keepalive, op.chunked);
	if(err != nil)
		die(op.id, "writing error response: "+err);

	if(errmsgstr != nil && (op.req == nil || op.req.method != HEAD)) {
		hwrite(op, errmsg);
		hwriteeof(op);
	}

	accesslog(op);
}

responderr(op: ref Op, st: int)
{
	return respond(op, st, nil, nil);
}

responderrmsg(op: ref Op, st: int, errmsg: string)
{
	if(errmsg == nil)
		errmsg = statusmsg(st);
	return respond(op, st, mkhtml(sprint("%d - %s", st, errmsg)), "text/html; charset=utf-8");
}

mkhtmlstart(msg: string): string
{
	return sprint("<html><head><style type=\"text/css\">h1 { font-size: 1.4em; } td, th { padding-left: 1em; padding-right: 1em; } td.mtime, td.size { text-align: right; }</style><title>%s</title></head><body>", htmlescape(msg));
}

mkhtml(msg: string): string
{
	return mkhtmlstart(msg)+sprint("<h1>%s</h1></body></html>\n", htmlescape(msg));
}

etag(path: string, op: ref Op, dir: Sys->Dir): string
{
	host := op.req.h.get("host");
	if(host == nil)
		host = "_default";
	return "\""+sha1(array of byte sprint("%d,%d,%s,%s,%s", dir.qid.vers, dir.mtime, host, op.lport, path))+"\"";
}

maxage(cfg: ref Cfg, nil: string): string
{
	return sprint("maxage=%d", cfg.cachesecs);
}

accesslog(op: ref Op)
{
	length := "";
	if(!op.chunked && op.length >= big 0)
		length = string op.length;
	if(accessfd != nil && op.req != nil)
		fprint(accessfd, "%d %d %s!%s %s!%s %q %q %q %q %q %q %q %q %q\n", op.id, op.now, op.rhost, op.rport, op.lhost, op.lport, http->methodstr(op.req.method), op.req.h.get("host"), op.req.url.path, sprint("HTTP/%d.%d", op.req.major, op.req.minor), op.resp.st, op.resp.stmsg, length, op.req.h.get("user-agent"), op.req.h.get("referer"));
}

findcgi(cfg: ref Cfg, path: string): (string, string, int)
{
	say(sprint("findcgi: len cfg.redirs %d", len cfg.redirs));
	for(l := cfg.cgipaths; l != nil; l = tl l)
		if(str->prefix((*hd l).t0, path))
			return *hd l;
	return (nil, nil, 0);
}

htmlescape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'<' =>	r += "&lt;";
		'>' =>	r += "&gt;";
		'&' =>	r += "&amp;";
		'"' =>	r += "&quot;";
		* =>	r += s[i:i+1];
		}
	return r;
}

pathsanitize(path: string): string
{
	say("path sanitize: "+path);
	trailslash := path != nil && path[len path-1] == '/';

	(nil, elems) := sys->tokenize(path, "/");
	say(sprint("path nelems: %d", len elems));
	r: list of string;
	for(; elems != nil; elems = tl elems)
		if(hd elems == ".")
			continue;
		else if(hd elems == "..") {
			if(r != nil)
				r = tl r;
		} else
			r = hd elems::r;
	s := "";	
	for(; r != nil; r = tl r)
		s = "/"+hd r+s;
	if(trailslash || s == "")
		s += "/";
	return s;
}

pathurls(s: string): string
{
	say("pathurls: "+s);
	(nil, l) := sys->tokenize(s, "/");
	r := "";
	i := 0;
	path := "./";
	for(l = rev(l); l != nil; l = tl l) {
		r = sprint(" <a href=\"%s\">%s/</a>", path, htmlescape(hd l))+r;
		if(i == 0)
			path = "../";
		else
			path += "../";
		i += 1;
	}
	r = sprint("<a href=\"%s\">/</a>", path)+r;
	return r;
}

cgivars(path, cgipath: string, req: ref Req, op: ref Op, length: big, environ: list of (string, string)): list of (string, string)
{
	servername := req.h.get("host");
	if(servername == nil)
		servername = op.lhost;
	pathinfo := path[len cgipath:];
	query := req.url.query;
	if(query != nil)
		query = query[1:];
	return	("CONTENT_LENGTH",	string length)::
		("GATEWAY_INTERFACE",	"CGI/1.1")::
		("SERVER_PROTOCOL",	http->versionstr(req.version()))::
		("SERVER_NAME",		servername)::
		("REQUEST_METHOD",	http->methodstr(req.method))::
		("REQUEST_URI",		req.url.packpath())::
		("SCRIPT_NAME",		cgipath)::
		("PATH_INFO",		pathinfo)::
		("PATH_TRANSLATED",	pathinfo)::
		("QUERY_STRING",	query)::
		("SERVER_ADDR",		op.lhost)::
		("SERVER_PORT",		op.lport)::
		("REMOTE_ADDR",		op.rhost)::
		("REMOTE_PORT",		op.rport)::
		("SERVER_SOFTWARE",	Version)::
		environ;
}

scgirequest(path, scgipath: string, req: ref Req, op: ref Op, length: big): array of byte
{
	l := ("SCGI", "1")::cgivars(path, scgipath, req, op, length, environment);
	s := "";
	for(h := l; h != nil; h = tl h)
		s += (hd h).t0+"\0"+(hd h).t1+"\0";
	for(h = req.h.all(); h != nil; h = tl h)
		s += cgivar((hd h).t0)+"\0"+(hd h).t1+"\0";
	return netstring(s);
}

cgivar(s: string): string
{
	r := "HTTP_";
	for(i := 0; i < len s; i++)
		if(s[i] != '-')
			r[len r] = s[i];
		else
			r[len r] = '_';
	return str->toupper(r);
}

netstring(s: string): array of byte
{
	return array of byte (sprint("%d:", len s)+s+",");
}

suffix(suf, s: string): int
{
	if(len suf > len s)
		return 0;
	return suf == s[len s-len suf:];
}

gettype(path: string): string
{
	for(i := 0; i < len types; i++)
		if(suffix(types[i].t0, path))
			return types[i].t1;
	if(!has(path, '.'))
		return "text/plain; charset=utf-8";
	return "application/octet-stream";
}

days := array[] of {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
months := array[] of {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

httpdate(t: int): string
{
	tm := daytime->gmt(t);
	return sprint("%s, %02d %s %d %02d:%02d:%02d GMT", days[tm.wday], tm.mday, months[tm.mon], tm.year+1900, tm.hour, tm.min, tm.sec);
}

readtoken(s: string): (string, string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] < ' ')
			return (nil, nil, "invalid control characters found");
		else if(str->in(s[i], "()<>@,;:\\\"/[]?={} \t"))
			break;
	return (s[:i], s[i:], nil);
}

tokenize(s: string): (list of string, string)
{
	token, err: string;
	l: list of string;
	for(;;) {
		(token, s, err) = readtoken(s);
		if(err != nil)
			return (nil, err);
		if(token != nil)
			l = token::l;
		s = str->drop(s, " \t");
		if(s == nil)
			break;
		if(s[0] != ',')
			return (nil, "expected comma as separator");
		s = str->drop(s[1:], " \t");
	}
	return (rev(l), nil);
}

# for http/1.1 a backslash may be used for escaping, not for http/1.0
readqs(s: string, v: int): (string, string, string)
{
	if(s == nil)
		return (nil, nil, nil);
	if(s[0] != '"')
		return (nil, s, nil);
	r := "\"";
	for(i := 1; i < len s; i++)
		if(s[i] < ' ')
			return (nil, nil, "invalid control character found inside quoted string");
		else if(v >= HTTP_11 && s[i] == '\\' && i+1 < len s && s[i+1] == '"')
			r[len r] = s[++i];
		else {
			r[len r] = s[i];
			if(s[i] == '"')
				return (r, s[i+1:], nil);
		}
	return (nil, nil, "quoted string not ended");
}

tokenizeqs(s: string, v: int): (list of string, string)
{
	r: list of string;
	qs, err: string;
	for(;;) {
		(qs, s, err) = readqs(s, v);
		if(err != nil)
			return (nil, err);
		if(qs != nil)
			r = qs::r;
		s = str->drop(s, " \t");
		if(s == nil)
			break;
		if(s[0] != ',')
			return (nil, "expected comma as separator");
		s = str->drop(s[1:], " \t");
	}
	return (rev(r), nil);
}

# i'm not going to parse three different date formats where a simple unix epoch integer would have sufficed.
# death to the bloat monster!
parsehttpdate(s: string): int
{
	mday, mon, year, hour, min, sec: int;

	(n, tokens) := sys->tokenize(s, " ");
	if(n != 6 || len hd tokens != 4 || (hd tokens)[3] != ',' || index(days, (hd tokens)[:3]) < 0)
		return 0;
	say("got a bit");
	if((mon = index(months, hd tl tl tokens)) < 0)
		return 0;
	say("got a month");
	(hn, htokens) := sys->tokenize(hd tl tl tl tl tokens, ":");
	if(hn != 3)
		return 0;
	say("got time");
	mday = int hd tl tokens;
	year = int hd tl tl tl tokens;
	hour = int hd htokens;
	min = int hd tl htokens;
	sec = int hd tl tl htokens;

	# last arg should be seconds offset for timezone, "luckily" http allows only gmt...
	return daytime->tm2epoch(ref Daytime->Tm(sec, min, hour, mday, mon, year-1900, 0, 0, s[1:], 0));
}

parserange(version: int, range: string, dir: Sys->Dir): (int, list of ref (big, big))
{
	if(range == nil || !(version >= HTTP_11))
		return (1, nil);

	if(!str->prefix("bytes", range))
		return (0, nil);
	range = range[len "bytes":];
	range = str->drop(range, " \t");
	if(!str->prefix("=", range))
		return (0, nil);
	range = str->drop(range[1:], " \t");

	r: list of ref (big, big);
	valid := 0;
	for(l := sys->tokenize(range, ",").t1; l != nil; l = tl l) {
		s := strip(hd l, " \t");
		if(s == nil)
			continue;
		if(s[0] == '-') {
			# single (negative) byte offset relative to end of file
			s = str->drop(s[1:], " \t");
			if(s == nil || str->drop(s, "0-9") != nil)
				return (1, nil);
			if(big s != big 0)
				valid = 1;
			i := dir.length - big s;
			if(i < big 0)
				i = big 0;
			if(i >= dir.length)
				i = dir.length - big 1;
			chat(0, sprint("adding single, (%bd, %bd)", i, dir.length));
			r = ref (i, dir.length)::r;
		} else {
			(first, last) := str->splitstrl(s, "-");
			if(stripws(str->drop(first, "0-9")) != nil || last == nil || str->drop(stripws(last[1:]), "0-9") != nil)
				return (1, nil);
			f := big first;
			e := dir.length;
			last = stripws(last[1:]);
			if(last != nil)
				e = big last+big 1;
			if(e > dir.length)
				e = dir.length;
			if(f > e)
				return (1, nil);
			if(f < dir.length)
				valid = 1;
			r = ref (f, e)::r;
			chat(0, sprint("adding two, (%bd, %bd)", f, e));
		}
	}
	return (valid, rev(r));
}

etagmatch(version: int, etag: string, etagstr: string, strong: int): int
{
	if(etagstr == "*")
		return 1;
	(l, err) := tokenizeqs(etagstr, version);
	if(err != nil)
		return 0;	# xxx respond with "bad request"?
	for(; l != nil; l = tl l)
		if(hd l == etag && (!strong || !str->prefix("W/", hd l)))
			return 1;
	return 0;
}

statusmsg(code: int): string
{
	for(i := 0; i < len statusmsgs && statusmsgs[i].t0 <= code; i++)
		if(code == statusmsgs[i].t0)
			return statusmsgs[i].t1;
	raise sprint("missing status message for code %d", code);
}

strip(s, cl: string): string
{
	return droptl(str->drop(s, cl), cl);
}

stripws(s: string): string
{
	return strip(s, " \t");
}

droptl(s, cl: string): string
{
	while(s != nil && str->in(s[len s-1], cl))
		s = s[:len s-1];
	return s;
}

index(a: array of string, s: string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == s)
			return i;
	return -1;
}

readaddr(id: int, path: string): (string, string)
{
	(s, err) := readfileline(path, 256);
	if(err != nil)
		die(id, err);
	(lhost, lport) := str->splitstrl(s, "!");
	if(lport != nil)
		lport = lport[1:];
	return (lhost, lport);
}

readfileline(path: string, maxsize: int): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sprint("open %s: %r", path));
	n := sys->read(fd, buf := array[maxsize] of byte, len buf);
	if(n < 0)
		return (nil, sprint("read %s: %r", path));
	s := string buf[:n];
	if(s != nil && s[len s-1] == '\n')
		s = s[:len s-1];
	return (s, nil);
}

readtime(): int
{
	n := sys->pread(timefd, d := array[64] of byte, len d, big 0);
	if(n < 0)
		fail(sprint("reading time: %r"));
	return int ((big string d[:n])/big 1000000);
}

byte2str(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%02x", int a[i]);
	return s;
}

sha1(a: array of byte): string
{
	r := array[keyring->SHA1dlen] of byte;
	keyring->sha1(a, len a, r, nil);
	return byte2str(r);
}

listlower(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = str->tolower(hd l)::r;
	return rev(r);
}

listhas(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

has(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return 1;
	return 0;
}

rev[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l::r;
	return r;
}

kill(pid: int)
{
	fd := sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		fprint(fd, "kill");
}

say(s: string)
{
	if(debugflag)
		fprint(fildes(2), "%s\n", s);
	if(errorfd != nil)
		fprint(errorfd, "%s\n", s);
}

chat(id: int, s: string)
{
	say(string id+" "+s);
}

die(id: int, s: string)
{
	fail(string id+" "+s);
}

fail(s: string)
{
	fprint(fildes(2), "%s\n", s);
	raise "fail:"+s;
}


Cfgs.init(file: string): (ref Cfgs, string)
{
	db := Db.open(file);
	if(db == nil)
		return (nil, sprint("db open %s: %r", file));
	c := ref Cfgs(file, db, nil, nil, chan of (string, string, chan of (ref Cfg, string)));
	err := cfgsread(c);
	if(err == nil)
		spawn cfgserver(c);
	return (c, err);
}

Cfgs.get(c: self ref Cfgs, host, port: string): (ref Cfg, string)
{
	if(!vhostflag) {
		if(c.default == nil)
			return (nil, "no config");
		return (c.default, nil);
	}
	c.getch <-= (host, port, respch := chan of (ref Cfg, string));
	return <-respch;
}

cfgfind(c: ref Cfgs, host, port: string): ref Cfg
{
	say(sprint("cfgfind, have %d configs", len c.configs));
	for(l := c.configs; l != nil; l = tl l) {
		(chost, cport, config) := hd l;
		say(sprint("testing against host %q port %q vs %q %q", chost, cport, host, port));
		if(host == chost && port == cport) {
			say("have match!");
			return config;
		}
	}
	return nil;
}

cfgserver(c: ref Cfgs)
{
	for(;;) {
		(host, port, respch) := <-c.getch;
		say(sprint("cfgserver, have request for host %q port %q", host, port));

		cfg := cfgfind(c, host, port);
		if(cfg == nil)
			cfg = c.default;
		if(cfg == nil)
			respch <-= (nil, "no config");
		else
			respch <-= (cfg, nil);
	}
}

cfgsread(c: ref Cfgs): string
{
	e: ref Dbentry; 
	(e, nil) = c.db.find(nil, "vhost");
	if(e != nil)
		vhostflag = 1;

	(e, nil) = c.db.find(nil, "ctlchan");
	if(e != nil) {
		s := e.findfirst("ctlchan");
		if(s != nil)
			ctlchan = s;
	}

	ptr: ref Attrdb->Dbptr;
	attr := "mime";
	for(;;) {
		(e, ptr) = c.db.find(ptr, attr);
		if(e == nil)
			break;
		ext := e.findfirst("ext");
		mtype := e.findfirst("type");
		if(ext == nil || mtype == nil)
			return sprint("bad mime type, ext=%q type=%q", ext, mtype);
		ntypes := array[len types+1] of (string, string);
		ntypes[0] = (ext, mtype);
		ntypes[1:] = types;
		types = ntypes;
	}
	ptr = nil;

	attr = "bind";
	for(;;) {
		(e, ptr) = c.db.find(ptr, attr);
		if(e == nil)
			break;
		addr := e.findfirst("addr");
		if(addr == nil)
			say("bad listen entry, missing/empty \"addr\" field, ignoring...");
		else
			addrs = addr::addrs;
	}
	ptr = nil;

	attr = "host";
	for(;;) {
		(e, ptr) = c.db.find(ptr, attr);
		if(e == nil)
			break;
		host := e.findfirst("host");
		port := e.findfirst("port");
		if(port == "")
			port = "80";
		(cfg, err) := cfgread(e);
		if(err != nil)
			return err;
		cfg.host = host;
		cfg.port = port;
		if(host == nil)
			c.default = cfg;
		c.configs = (host, port, cfg)::c.configs;
		say(sprint("cfgsread, have host %q port %q", host, port));
	}
	ptr = nil;

	attr = "alias";
	for(;;) {
		(e, ptr) = c.db.find(ptr, attr);
		if(e == nil)
			break;
		host := e.findfirst("host");
		port := e.findfirst("port");
		usehost := e.findfirst("usehost");
		useport := e.findfirst("useport");
		if(port == nil)
			port = "80";
		if(usehost == nil)
			usehost = host;
		if(useport == nil)
			useport = port;
		if(usehost == host && useport == port)
			return "alias line aliases host and port to itself, ignoring";
		cfg := cfgfind(c, usehost, useport);
		if(cfg == nil)
			return sprint("alias references non-existing usehost=%q useport=%q", usehost, useport);
		c.configs = (host, port, cfg)::c.configs;
		say(sprint("cfgsread, have alias host %q port %q usehost %q useport %q", host, port, usehost, useport));
	}
	ptr = nil;

	return nil;
}

Cfg.new(): ref Cfg
{
	return ref Cfg("", "80", 0, 0, nil, nil, nil, nil, nil);
}

cfgread(e: ref Dbentry): (ref Cfg, string)
{
	cfg := Cfg.new();

	for(l := list of {"listings", "cachesecs"}; l != nil; l = tl l) {
		for(r := e.find(hd l); r != nil; r = tl r) {
			for(attrs := (hd r).t1; attrs != nil; attrs = tl attrs) {
				val := (hd attrs).val;
				case (hd attrs).attr {
				"listings" =>	cfg.listings = 1;
				"cachesecs" =>	cfg.cachesecs = int val;
				* =>	say(sprint("ignoring config attribute %q", (hd attrs).attr));
				}
			}
		}
	}

	for(l = list of {"listen", "redir", "auth", "index", "cgi", "scgi"}; l != nil; l = tl l) {
		attr := hd l;
		for(r := e.find(attr); r != nil; r = tl r) {
			(tups, nil) := hd r;
			
			case attr {
			"listen" =>
				ip := tups.find("ip");
				port := tups.find("port");
				if(ip == nil)
					return (nil, sprint("missing ip in listen line"));
				ipstr := (hd ip).val;
				say(sprint("ipstr %q", ipstr));
				(ok, ipaddr) := IPaddr.parse(ipstr);
				if(ok != 0)
					return (nil, sprint("invalid ip address: %q", ipstr));
				portstr := "80";
				if(port != nil)
					portstr = (hd port).val;
				cfg.addrs = (ref (ipaddr.text(), string int portstr))::cfg.addrs;
			"redir" =>
				src := tups.find("src");
				dst := tups.find("dst");
				if(src == nil || dst == nil)
					return (nil, "missing src or dst in redir line");
				(repl, rerr) := Repl.parse((hd src).val, (hd dst).val);
				if(rerr != nil)
					return (nil, "parsing redir: "+rerr);
				cfg.redirs = repl::cfg.redirs;
			"auth" =>
				path := tups.find("path");
				realm := tups.find("realm");
				user := tups.find("user");
				pass := tups.find("pass");
				if(path == nil || realm == nil || user == nil || pass == nil)
					return (nil, "missing field in auth line");
				cfg.auths = ref ((hd path).val, (hd realm).val, base64->enc(array of byte ((hd user).val+":"+(hd pass).val)))::cfg.auths;
			"index" =>
				for(file := tups.find("file"); file != nil; file = tl file)
					cfg.indexfiles = (hd file).val::cfg.indexfiles;
			"cgi" =>
				path := tups.find("path");
				cmd := tups.find("cmd");
				if(path == nil || cmd == nil)
					return (nil, "missing path or cmd in cgi line");
				cfg.cgipaths = ref ((hd path).val, (hd cmd).val, Cgi)::cfg.cgipaths;
			"scgi" =>
				path := tups.find("path");
				addr := tups.find("addr");
				if(path == nil || addr == nil)
					return (nil, "missing path or addr in scgi line");
				cfg.cgipaths = ref ((hd path).val, (hd addr).val, Scgi)::cfg.cgipaths;
			}
		}
	}
	cfg.addrs = rev(cfg.addrs);
	cfg.cgipaths = rev(cfg.cgipaths);
	cfg.indexfiles = rev(cfg.indexfiles);
	cfg.redirs = rev(cfg.redirs);
	cfg.auths = rev(cfg.auths);
	return (cfg, nil);
}


Repl.parse(restr, rulestr: string): (ref Repl, string)
{
	(re, err) := regex->compile(restr, 1);
	if(err != nil)
		return (nil, "bad regex: "+err);

	rule: list of ref (string, int);
	maxrepl := 0;
	for(;;) {
		(l, r) := str->splitstrl(rulestr, "$");
		if(r == nil) {
			rule = ref (l, -1)::rule;
			break;
		}
		r = r[1:];
		if(r != nil && r[0] == '$') {
			rule = ref (l+"$", -1)::rule;
			r = r[1:];
		} else {
			num := str->take(r, "0-9");
			if(num == nil)
				return (nil, "bad rule: $ not followed by number or dollar");
			n := int num;
			if(n > maxrepl)
				maxrepl = n;
			rule = ref (l, n)::rule;
			r = r[len num:];
		}
		rulestr = r;
	}
	rule = rev(rule);
	return (ref Repl(re, rule, maxrepl), nil);
}

Repl.apply(r: self ref Repl, s: string): (int, string, string)
{
	m := regex->executese(r.re, s, (0, len s), 1, 1);
	if(m == nil)
		return (0, nil, nil);
	if(r.maxrepl > len m-1)
		return (0, nil, "replacement group too high for regular expression");
	res := "";
	for(rl := r.rule; rl != nil; rl = tl rl) {
		(part, index) := *(hd rl);
		res += part;
		if(index == -1)
			continue;
		(b, e) := m[index];
		if(b == -1 || e == -1)
			return (0, nil, "replacement group did not match in regular expression");
		res += s[b:e];
	}
	return (1, res, nil);
}
