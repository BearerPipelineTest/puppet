libdir = File.join(File.dirname(__FILE__), '../lib')
unless $:.include?(libdir)
    $:.unshift libdir
end

require 'puppet'
require 'test/unit'

module TestPuppet
    def newcomp(name,*ary)
        if name.is_a?(Puppet::Type)
            ary.unshift name
            name = name.name
        end
        comp = Puppet::Type::Component.create(
            :name => name
        )
        ary.each { |item| comp.push item }

        return comp
    end

    def setup
        if defined? @@testcount
            @@testcount += 1
        else
            @@testcount = 0
        end

        @configpath = File.join(tmpdir,
            self.class.to_s + "configdir" + @@testcount.to_s
        )

        Puppet[:puppetconf] = @configpath
        Puppet[:puppetvar] = @configpath

        unless File.exists?(@configpath)
            Dir.mkdir(@configpath)
        end

        @@tmpfiles = [@configpath, tmpdir()]
        @@tmppids = []

        if $0 =~ /.+\.rb/
            Puppet[:logdest] = :console
            Puppet[:loglevel] = :debug
            $VERBOSE = 1
        else
            Puppet::Log.close
            Puppet[:logdest] = "/dev/null"
            Puppet[:httplog] = "/dev/null"
        end
    end


    def spin
        # Just disable spin, unless we really need it
        return
        if Puppet[:debug]
            return
        end
        @modes = %w{| / - \\}
        unless defined? @mode
            @mode = 0
        end

        $stderr.print "%s" % @modes[@mode]
        if @mode == @modes.length - 1
            @mode = 0
        else
            @mode += 1
        end
        $stderr.flush
    end

    # stop any services that might be hanging around
    def stopservices
        if stype = Puppet::Type.type(:service)
            stype.each { |service|
                service[:running] = false
                service.sync
            }
        end
    end

    def teardown
        stopservices
        @@tmpfiles.each { |file|
            if FileTest.exists?(file)
                system("chmod -R 755 %s" % file)
                system("rm -rf %s" % file)
            end
        }
        @@tmpfiles.clear

        @@tmppids.each { |pid|
            %x{kill -INT #{pid} 2>/dev/null}
        }
        @@tmppids.clear
        Puppet::Type.allclear
        Puppet.clear

        # reset all of the logs
        Puppet::Log.close
    end

    def tempfile
        if defined? @tmpfilenum
            @tmpfilenum += 1
        else
            @tmpfilenum = 1
        end
        f = File.join(self.tmpdir(), self.class.to_s + "testfile" + @tmpfilenum.to_s)
        @@tmpfiles << f
        return f
    end

    def testdir
        if defined? @testdirnum
            @testdirnum += 1
        else
            @testdirnum = 1
        end
        d = File.join(self.tmpdir(), self.class.to_s + "testdir" + @testdirnum.to_s)
        @@tmpfiles << d
        return d
    end

    def tmpdir
        unless defined? @tmpdir and @tmpdir
            @tmpdir = case Facter["operatingsystem"].value
            when "Darwin": "/private/tmp"
            when "SunOS": "/var/tmp"
            else
                "/tmp"
            end

            @tmpdir = File.join(@tmpdir, "puppettesting")

            unless File.exists?(@tmpdir)
                FileUtils.mkdir_p(@tmpdir)
                File.chmod(01777, @tmpdir)
            end
        end
        @tmpdir
    end

    def assert_rollback_events(trans, events, msg)
        run_events(:rollback, trans, events, msg)
    end

    def assert_events(comp, events, msg = nil)
        trans = nil
        msg ||= comp.name
        assert_nothing_raised("Component %s failed" % [msg]) {
            trans = comp.evaluate
        }

        run_events(:evaluate, trans, events, msg)
    end

    def run_events(type, trans, events, msg)
        case type
        when :evaluate, :rollback: # things are hunky-dory
        else
            raise Puppet::DevError, "Incorrect run_events type"
        end

        method = type

        newevents = nil
        assert_nothing_raised("Transaction %s %s failed" % [type, msg]) {
            newevents = trans.send(method).reject { |e| e.nil? }.collect { |e|
                e.event
            }
        }

        assert_equal(events, newevents, "Incorrect %s %s events" % [type, msg])

        return trans
    end

    def nonrootuser
        Etc.passwd { |user|
            if user.uid != Process.uid
                return user
            end
        }
    end

    def nonrootgroup
        Etc.group { |group|
            if group.gid != Process.gid
                return group
            end
        }
    end
end


module ServerTest
    include TestPuppet
    def setup
        super

        if defined? @@port
            @@port += 1
        else
            @@port = 8085
        end
    end

    # create a simple manifest that just creates a file
    def mktestmanifest
        file = File.join(Puppet[:puppetconf], "%ssite.pp" % (self.class.to_s + "test"))
        @createdfile = File.join(tmpdir(), self.class.to_s + "servermanifesttesting")

        File.open(file, "w") { |f|
            f.puts "file { \"%s\": create => true, mode => 755 }\n" % @createdfile
        }

        @@tmpfiles << @createdfile
        @@tmpfiles << file

        return file
    end

    # create a server, forked into the background
    def mkserver(handlers = nil)
        # our default handlers
        unless handlers
            handlers = {
                :CA => {}, # so that certs autogenerate
                :Master => {
                    :File => mktestmanifest(),
                    :UseNodes => false
                },
            }
        end

        # then create the actual server
        server = nil
        assert_nothing_raised {
            server = Puppet::Server.new(
                :Port => @@port,
                :Handlers => handlers
            )
        }

        # fork it
        spid = fork {
            trap(:INT) { server.shutdown }
            server.start
        }

        # and store its pid for killing
        @@tmppids << spid

        # give the server a chance to do its thing
        sleep 1 
        return spid
    end

end

module ExeTest
    include ServerTest
    unless ENV["PATH"] =~ /puppet/
        # ok, we have to add the bin directory to our search path
        ENV["PATH"] += ":" + File.join($puppetbase, "bin")

        # and then the library directories
        libdirs = $:.find_all { |dir|
            dir =~ /puppet/ or dir =~ /\.\./
        }
        ENV["RUBYLIB"] = libdirs.join(":")
    end

    def startmasterd(args = "")
        output = nil

        manifest = mktestmanifest()
        args += " --manifest %s" % manifest
        args += " --confdir %s" % Puppet[:puppetconf]
        args += " --vardir %s" % Puppet[:puppetvar]
        args += " --port %s" % @@port
        args += " --nonodes"
        args += " --autosign"

        cmd = "puppetmasterd %s" % args


        assert_nothing_raised {
            output = %x{#{cmd}}.chomp
        }
        assert($? == 0, "Puppetmasterd exit status was %s" % $?)
        assert_equal("", output, "Puppetmasterd produced output %s" % output)
        sleep(1)

        return manifest
    end

    def stopmasterd(running = true)
        ps = Facter["ps"].value || "ps -ef"

        pidfile = File.join(Puppet[:puppetvar], "puppetmasterd.pid")

        pid = nil
        if FileTest.exists?(pidfile)
            pid = File.read(pidfile).chomp.to_i
            File.unlink(pidfile)
        end

        if running or pid
            runningpid = nil
            %x{#{ps}}.chomp.split(/\n/).each { |line|
                if line =~ /ruby.+puppetmasterd/
                    next if line =~ /\.rb/ # skip the test script itself
                    ary = line.sub(/^\s+/, '').split(/\s+/)
                    runningpid = ary[1].to_i
                end
            }

            if running
                assert(runningpid, "Process is not running")
                assert_equal(pid, runningpid, "PIDs are not equal")
            else
                return
            end
        end

        # we default to mandating that it's running, but teardown
        # doesn't require that
        if pid
            if pid == $$
                raise Puppet::Error, "Tried to kill own pid"
            end
            assert_nothing_raised {
                Process.kill("-INT", pid)
            }
        end
    end

    def teardown
        stopmasterd(false)
        super
    end
end

module FileTesting
    include TestPuppet
    def cycle(comp)
        trans = nil
        assert_nothing_raised {
            trans = comp.evaluate
        }
        assert_nothing_raised {
            trans.evaluate
        }
    end

    def randlist(list)
        num = rand(4)
        if num == 0
            num = 1
        end
        set = []

        ret = []
        num.times { |index|
            item = list[rand(list.length)]
            if set.include?(item)
                redo
            end

            ret.push item
        }
        return ret
    end

    def mkranddirsandfiles(dirs = nil,files = nil,depth = 3)
        if depth < 0
            return
        end

        unless dirs
            dirs = %w{This Is A Set Of Directories}
        end

        unless files
            files = %w{and this is a set of files}
        end

        tfiles = randlist(files)
        tdirs = randlist(dirs)

        tfiles.each { |file|
            File.open(file, "w") { |of|
                4.times {
                    of.puts rand(100)
                }
            }
        }

        tdirs.each { |dir|
            # it shouldn't already exist, but...
            unless FileTest.exists?(dir)
                Dir.mkdir(dir)
                FileUtils.cd(dir) {
                    mkranddirsandfiles(dirs,files,depth - 1)
                }
            end
        }
    end

    def file_list(dir)
        list = nil
        FileUtils.cd(dir) {
            list = %x{find . 2>/dev/null}.chomp.split(/\n/)
        }
        return list
    end

    def assert_trees_equal(fromdir,todir)
        assert(FileTest.directory?(fromdir))
        assert(FileTest.directory?(todir))

        # verify the file list is the same
        fromlist = nil
        FileUtils.cd(fromdir) {
            fromlist = %x{find . 2>/dev/null}.chomp.split(/\n/).reject { |file|
                ! FileTest.readable?(file)
            }.sort
        }
        tolist = file_list(todir).sort

        fromlist.sort.zip(tolist.sort).each { |a,b|
            assert_equal(a, b,
            "Fromfile %s with length %s does not match tofile %s with length %s" %
                    [a, fromlist.length, b, tolist.length])
        }
        #assert_equal(fromlist,tolist)

        # and then do some verification that the files are actually set up
        # the same
        checked = 0
        fromlist.each_with_index { |file,i|
            fromfile = File.join(fromdir,file)
            tofile = File.join(todir,file)
            fromstat = File.stat(fromfile)
            tostat = File.stat(tofile)
            [:ftype,:gid,:mode,:uid].each { |method|
                assert_equal(
                    fromstat.send(method),
                    tostat.send(method)
                )

                next if fromstat.ftype == "directory"
                if checked < 10 and i % 3 == 0
                    from = File.open(fromfile) { |f| f.read }
                    to = File.open(tofile) { |f| f.read }

                    assert_equal(from,to)
                    checked += 1
                end
            }
        }
    end

    def random_files(dir)
        checked = 0
        list = file_list(dir)
        list.reverse.each_with_index { |file,i|
            path = File.join(dir,file)
            stat = File.stat(dir)
            if checked < 10 and (i % 3) == 2
                unless yield path
                    next
                end
                checked += 1
            end
        }
    end

    def delete_random_files(dir)
        deleted = []
        random_files(dir) { |file|
            stat = File.stat(file)
            begin
                if stat.ftype == "directory"
                    false
                else
                    deleted << file
                    File.unlink(file)
                    true
                end
            rescue => detail
                # we probably won't be able to open our own secured files
                puts detail
                false
            end
        }

        return deleted
    end

    def add_random_files(dir)
        added = []
        random_files(dir) { |file|
            stat = File.stat(file)
            begin
                if stat.ftype == "directory"
                    name = File.join(file,"file" + rand(100).to_s)
                    File.open(name, "w") { |f|
                        f.puts rand(10)
                    }
                    added << name
                else
                    false
                end
            rescue => detail
                # we probably won't be able to open our own secured files
                puts detail
                false
            end
        }
        return added
    end

    def modify_random_files(dir)
        modded = []
        random_files(dir) { |file|
            stat = File.stat(file)
            begin
                if stat.ftype == "directory"
                    false
                else
                    File.open(file, "w") { |f|
                        f.puts rand(10)
                    }
                    modded << name
                    true
                end
            rescue => detail
                # we probably won't be able to open our own secured files
                puts detail
                false
            end
        }
        return modded
    end

    def readonly_random_files(dir)
        modded = []
        random_files(dir) { |file|
            stat = File.stat(file)
            begin
                if stat.ftype == "directory"
                    File.new(file).chmod(0111)
                else
                    File.new(file).chmod(0000)
                end
                modded << file
            rescue => detail
                # we probably won't be able to open our own secured files
                puts detail
                false
            end
        }
        return modded
    end

    def conffile
        File.join($puppetbase,"examples/root/etc/configfile")
    end
end

module ParserTesting
    include TestPuppet
    AST = Puppet::Parser::AST

    def astarray
        AST::ASTArray.new(
            :children => []
        )
    end

    def classobj(name, args = {})
        unless args.include?(:name)
            args[:name] = nameobj(name)
        end
        unless args.include?(:code)
            args[:code] = AST::ASTArray.new(
                :file => tempfile(),
                :line => rand(100),
                :children => [
                    varobj("%svar" % name, "%svalue" % name),
                    fileobj("/%s" % name)
                ]
            )
        end
        assert_nothing_raised("Could not create class %s" % name) {
            return AST::ClassDef.new(args)
        }
    end

    def compobj(name, args = {})
        args[:file] = tempfile()
        args[:line] = rand(100)
        args[:name] = nameobj(name)
        args[:code] = AST::ASTArray.new(
            :file => tempfile(),
            :line => rand(100),
            :children => [
                varobj("%svar" % name, "%svalue" % name),
                fileobj("/%s" % name)
            ]
        )
        assert_nothing_raised("Could not create compdef %s" % name) {
            return AST::CompDef.new(args)
        }
    end

    def fileobj(path, hash = {"owner" => "root"})
        assert_nothing_raised("Could not create file %s" % path) {
            return AST::ObjectDef.new(
                :file => tempfile(),
                :line => rand(100),
                :name => stringobj(path),
                :type => nameobj("file"),
                :params => objectinst(hash)
            )
        }
    end

    def nameobj(name)
        assert_nothing_raised("Could not create name %s" % name) {
            return AST::Name.new(
                :file => tempfile(),
                :line => rand(100),
                :value => name
            )
        }
    end

    def nodeobj(name)
        assert_nothing_raised("Could not create node %s" % name) {
            return AST::NodeDef.new(
                :file => tempfile(),
                :line => rand(100),
                :names => nameobj(name),
                :code => AST::ASTArray.new(
                    :children => [
                        varobj("%svar" % name, "%svalue" % name),
                        fileobj("/%s" % name)
                    ]
                )
            )
        }
    end

    def objectinst(hash)
        assert_nothing_raised("Could not create object instance") {
            params = hash.collect { |param, value|
                objectparam(param, value)
            }
            return AST::ObjectInst.new(
                :file => tempfile(),
                :line => rand(100),
                :children => params
            )
        }
    end

    def objectparam(param, value)
        assert_nothing_raised("Could not create param %s" % param) {
            return AST::ObjectParam.new(
                :file => tempfile(),
                :line => rand(100),
                :param => nameobj(param),
                :value => stringobj(value)
            )
        }
    end

    def stringobj(value)
        AST::String.new(
            :file => tempfile(),
            :line => rand(100),
            :value => value
        )
    end

    def varobj(name, value)
        assert_nothing_raised("Could not create %s code" % name) {
            return AST::VarDef.new(
                :file => tempfile(),
                :line => rand(100),
                :name => nameobj(name),
                :value => stringobj(value)
            )
        }
    end
end

class PuppetTestSuite
    attr_accessor :subdir

    def self.list
        Dir.entries(".").find_all { |file|
            FileTest.directory?(file) and file !~ /^\./
        }
    end

    def initialize(name)
        unless FileTest.directory?(name)
            puts "TestSuites are directories containing test cases"
            puts "no such directory: %s" % name
            exit(65)
        end

        # load each of the files
        Dir.entries(name).collect { |file|
            File.join(name,file)
        }.find_all { |file|
            FileTest.file?(file) and file =~ /\.rb$/
        }.sort { |a,b|
            # in the order they were modified, so the last modified files
            # are loaded and thus displayed last
            File.stat(b) <=> File.stat(a)
        }.each { |file|
            require file
        }
    end
end

# a list of files that we can parse for testing
def textfiles
    textdir = File.join($puppetbase,"examples","code", "snippets")
    Dir.entries(textdir).reject { |f|
        f =~ /^\./ or f =~ /fail/
    }.each { |f|
        yield File.join(textdir, f)
    }
end

def failers
    textdir = File.join($puppetbase,"examples","code", "failers")
    # only parse this one file now
    files = Dir.entries(textdir).reject { |file|
        file =~ %r{\.swp}
    }.reject { |file|
        file =~ %r{\.disabled}
    }.collect { |file|
        File.join(textdir,file)
    }.find_all { |file|
        FileTest.file?(file)
    }.sort.each { |file|
        Puppet.debug "Processing %s" % file
        yield file
    }
end

# $Id$
