module Vmpooler
  class PoolManager
    def initialize(config, pools, logger, redis, graphite=nil)
      $config = config

      $pools   = pools

      # Load logger library
      $logger = logger

      unless graphite.nil?
        $graphite = graphite
      end

      # Connect to Redis
      $redis = redis

      # vSphere object
      $vsphere = {}

      # Our thread-tracker object
      $threads = {}
    end

    # Check the state of a VM
    def check_pending_vm(vm, pool, timeout)
      Thread.new do
        host = $vsphere[pool].find_vm(vm)

        if host
          if
            (host.summary) &&
            (host.summary.guest) &&
            (host.summary.guest.hostName) &&
            (host.summary.guest.hostName == vm)

            begin
              Socket.getaddrinfo(vm, nil)
            rescue
            end

            clone_time = $redis.hget('vmpooler__vm__' + vm, 'clone')
            finish = '%.2f' % (Time.now - Time.parse(clone_time)) if clone_time

            $redis.smove('vmpooler__pending__' + pool, 'vmpooler__ready__' + pool, vm)
            $redis.hset('vmpooler__boot__' + Date.today.to_s, pool + ':' + vm, finish)

            $logger.log('s', "[>] [#{pool}] '#{vm}' moved to 'ready' queue")
          end
        else
          clone_stamp = $redis.hget('vmpooler__vm__' + vm, 'clone')

          if
            (clone_stamp) &&
            (((Time.now - Time.parse(clone_stamp)) / 60) > timeout)

            $redis.smove('vmpooler__pending__' + pool, 'vmpooler__completed__' + pool, vm)

            $logger.log('d', "[!] [#{pool}] '#{vm}' marked as 'failed' after #{timeout} minutes")
          end
        end
      end
    end

    def check_ready_vm(vm, pool, ttl)
      Thread.new do
        if ttl > 0
          if (((Time.now - host.runtime.bootTime) / 60).to_s[/^\d+\.\d{1}/].to_f) > ttl
            $redis.smove('vmpooler__ready__' + pool, 'vmpooler__completed__' + pool, vm)

            $logger.log('d', "[!] [#{pool}] '#{vm}' reached end of TTL after #{ttl} minutes, removed from 'ready' queue")
          end
        end

        check_stamp = $redis.hget('vmpooler__vm__' + vm, 'check')

        if
          (!check_stamp) ||
          (((Time.now - Time.parse(check_stamp)) / 60) > $config[:config]['vm_checktime'])

          $redis.hset('vmpooler__vm__' + vm, 'check', Time.now)

          host = $vsphere[pool].find_vm(vm) ||
                 $vsphere[pool].find_vm_heavy(vm)[vm]

          if host
            if
              (host.runtime) &&
              (host.runtime.powerState) &&
              (host.runtime.powerState != 'poweredOn')

              $redis.smove('vmpooler__ready__' + pool, 'vmpooler__completed__' + pool, vm)

              $logger.log('d', "[!] [#{pool}] '#{vm}' appears to be powered off, removed from 'ready' queue")
            end

            if
              (host.summary.guest) &&
              (host.summary.guest.hostName) &&
              (host.summary.guest.hostName != vm)

              $redis.smove('vmpooler__ready__' + pool, 'vmpooler__completed__' + pool, vm)

              $logger.log('d', "[!] [#{pool}] '#{vm}' has mismatched hostname, removed from 'ready' queue")
            end
          else
            $redis.srem('vmpooler__ready__' + pool, vm)

            $logger.log('s', "[!] [#{pool}] '#{vm}' not found in vCenter inventory, removed from 'ready' queue")
          end

          begin
            Timeout.timeout(5) do
              TCPSocket.new vm, 22
            end
          rescue
            if $redis.smove('vmpooler__ready__' + pool, 'vmpooler__completed__' + pool, vm)
              $logger.log('d', "[!] [#{pool}] '#{vm}' is unreachable, removed from 'ready' queue")
            end
          end
        end
      end
    end

    def check_running_vm(vm, pool, ttl)
      Thread.new do
        host = $vsphere[pool].find_vm(vm)

        if host
          if
            (host.runtime) &&
            (host.runtime.powerState != 'poweredOn')

            $redis.smove('vmpooler__running__' + pool, 'vmpooler__completed__' + pool, vm)

            $logger.log('d', "[!] [#{pool}] '#{vm}' appears to be powered off or dead")
          else
            if
              (host.runtime) &&
              (host.runtime.bootTime)
              ((((Time.now - host.runtime.bootTime) / 60).to_s[/^\d+\.\d{1}/].to_f) > ttl)

              $redis.smove('vmpooler__running__' + pool, 'vmpooler__completed__' + pool, vm)

              $logger.log('d', "[!] [#{pool}] '#{vm}' reached end of TTL after #{ttl} minutes")
            end
          end
        end
      end
    end

    # Clone a VM
    def clone_vm(template, folder, datastore, target, customize)
      Thread.new do
        vm = {}

        if template =~ /\//
          templatefolders = template.split('/')
          vm['template'] = templatefolders.pop
        end

        if templatefolders
          vm[vm['template']] = $vsphere[vm['template']].find_folder(templatefolders.join('/')).find(vm['template'])
        else
          fail 'Please provide a full path to the template'
        end

        if vm['template'].length == 0
          fail "Unable to find template '#{vm['template']}'!"
        end

        # Generate a randomized hostname
        o = [('a'..'z'), ('0'..'9')].map(&:to_a).flatten
        vm['hostname'] = o[rand(25)] + (0...14).map { o[rand(o.length)] }.join

        # Add VM to Redis inventory ('pending' pool)
        $redis.sadd('vmpooler__pending__' + vm['template'], vm['hostname'])
        $redis.hset('vmpooler__vm__' + vm['hostname'], 'clone', Time.now)
        $redis.hset('vmpooler__vm__' + vm['hostname'], 'template', vm['template'])

        # Annotate with creation time, origin template, etc.
        configSpec = RbVmomi::VIM.VirtualMachineConfigSpec(
          annotation: JSON.pretty_generate(
              name: vm['hostname'],
              created_by: $config[:vsphere]['username'],
              base_template: vm['template'],
              creation_timestamp: Time.now.utc
           )
        )

        # Choose a clone target and pool
        if target
          $clone_target = $vsphere[vm['template']].find_least_used_host(target)
          $clone_pool = $vsphere[vm['template']].find_pool(target)
        elsif $config[:config]['clone_target']
          $clone_target = $vsphere[vm['template']].find_least_used_host($config[:config]['clone_target'])
          $clone_pool = $vsphere[vm['template']].find_pool($config[:config]['clone_target'])
        end

        # Put the VM in the specified folder and resource pool
        relocateSpec = RbVmomi::VIM.VirtualMachineRelocateSpec(
          datastore: $vsphere[vm['template']].find_datastore(datastore),
          host: $clone_target,
          pool: $clone_pool,
          diskMoveType: :moveChildMostDiskBacking
        )
 
        # Do we need to customize the VM's?
        if customize
          # Save domain for easier usage
          cust_domain = $config[:config]['domain']
          cust_dns_servers = $config[:config]['dns_servers'] ||= []

          # Build IP Settings
          cust_ip_settings = RbVmomi::VIM::CustomizationIPSettings.new(
            "ip" => RbVmomi::VIM::CustomizationDhcpIpGenerator.new()
          )
          cust_ip_settings.dnsDomain = cust_domain

          # Build the Custom Adapter Mapping Supports only one eth right now
          cust_adapter_mapping = [RbVmomi::VIM::CustomizationAdapterMapping.new(
            "adapter" => cust_ip_settings
          )]

          # Build global IP settings
          cust_global_ip_settings = RbVmomi::VIM::CustomizationGlobalIPSettings.new(
            :dnsServerList => cust_dns_servers,
            :dnsSuffixList => [cust_domain]
          )

          # Build hostname object
          cust_hostname = RbVmomi::VIM::CustomizationFixedName.new(:name => vm['hostname'])

          # Build the CustomizationLinuxPrep Object
          cust_prep = RbVmomi::VIM::CustomizationLinuxPrep.new(
            :domain      => cust_domain,
            :hostName    => cust_hostname
            #:hwClockUTC => cust_hwclockutc,
            #:timeZone   => cust_timezone
            )

          # Customize the VM
          customizationSpec = RbVmomi::VIM::CustomizationSpec.new(
            :identity         => cust_prep,
            :globalIPSettings => cust_global_ip_settings,
            :nicSettingMap    => cust_adapter_mapping
          )
        end

        # Make sure we've got a customization_spec value
        customization_spec ||= nil

        # Create a clone spec
        spec = RbVmomi::VIM.VirtualMachineCloneSpec(
          location: relocateSpec,
          config: configSpec,
          customization: customizationSpec,
          powerOn: true,
          template: false
        )

        # Clone the VM
        $logger.log('d', "[ ] [#{vm['template']}] '#{vm['hostname']}' is being cloned from '#{vm['template']}'")

        begin
          start = Time.now
          vm[vm['template']].CloneVM_Task(
            folder: $vsphere[vm['template']].find_folder(folder),
            name: vm['hostname'],
            spec: spec
          ).wait_for_completion
          finish = '%.2f' % (Time.now - start)

          $redis.hset('vmpooler__clone__' + Date.today.to_s, vm['template'] + ':' + vm['hostname'], finish)
          $redis.hset('vmpooler__vm__' + vm['hostname'], 'clone_time', finish)

          $logger.log('s', "[+] [#{vm['template']}] '#{vm['hostname']}' cloned from '#{vm['template']}' in #{finish} seconds")
        rescue
          $logger.log('s', "[!] [#{vm['template']}] '#{vm['hostname']}' clone appears to have failed")
          $redis.srem('vmpooler__pending__' + vm['template'], vm['hostname'])
        end

        $redis.decr('vmpooler__tasks__clone')

        begin
          $graphite.log($config[:graphite]['prefix'] + ".clone.#{vm['template']}", finish) if defined? $graphite
        rescue
        end
      end
    end

    # Destroy a VM
    def destroy_vm(vm, pool)
      Thread.new do
        $redis.srem('vmpooler__completed__' + pool, vm)
        $redis.hdel('vmpooler__active__' + pool, vm)
        $redis.hset('vmpooler__vm__' + vm, 'destroy', Time.now)

        host = $vsphere[pool].find_vm(vm) ||
               $vsphere[pool].find_vm_heavy(vm)[vm]

        if host
          start = Time.now

          if
            (host.runtime) &&
            (host.runtime.powerState) &&
            (host.runtime.powerState == 'poweredOn')

            $logger.log('d', "[ ] [#{pool}] '#{vm}' is being shut down")
            host.PowerOffVM_Task.wait_for_completion
          end

          host.Destroy_Task.wait_for_completion
          finish = '%.2f' % (Time.now - start)

          $logger.log('s', "[-] [#{pool}] '#{vm}' destroyed in #{finish} seconds")

          $graphite.log($config[:graphite]['prefix'] + ".destroy.#{pool}", finish) if defined? $graphite
        end
      end
    end

    def check_pool(pool)
      $logger.log('d', "[*] [#{pool['name']}] starting worker thread")

      $threads[pool['name']] = Thread.new do
        $vsphere[pool['name']] ||= Vmpooler::VsphereHelper.new
        loop do
          # INVENTORY
          inventory = {}
          begin
            base = $vsphere[pool['name']].find_folder(pool['folder'])

            base.childEntity.each do |vm|
              if
                (! $redis.sismember('vmpooler__running__' + pool['name'], vm['name'])) &&
                (! $redis.sismember('vmpooler__ready__' + pool['name'], vm['name'])) &&
                (! $redis.sismember('vmpooler__pending__' + pool['name'], vm['name'])) &&
                (! $redis.sismember('vmpooler__completed__' + pool['name'], vm['name'])) &&
                (! $redis.sismember('vmpooler__discovered__' + pool['name'], vm['name']))

                $redis.sadd('vmpooler__discovered__' + pool['name'], vm['name'])

                $logger.log('s', "[?] [#{pool['name']}] '#{vm['name']}' added to 'discovered' queue")
              end

              inventory[vm['name']] = 1
            end
          rescue
          end

          # RUNNING
          $redis.smembers('vmpooler__running__' + pool['name']).each do |vm|
            if inventory[vm]
              if pool['running_ttl']
                begin
                  check_running_vm(vm, pool['name'], pool['running_ttl'])
                rescue
                end
              else
                begin
                  check_running_vm(vm, pool['name'], '720')
                rescue
                end
              end
            end
          end

          # READY
          $redis.smembers('vmpooler__ready__' + pool['name']).each do |vm|
            if inventory[vm]
              begin
                check_ready_vm(vm, pool['name'], pool['ready_ttl'] || 0)
              rescue
              end
            else
              $logger.log('d', "[*] [#{pool['name']}] vm #{vm} is not in inventory, removing from 'ready' queue")
              $redis.srem('vmpooler__ready__' + pool['name'], vm)
              $redis.del('vmpooler__vm__' + vm)
            end
          end

          # PENDING
          $redis.smembers('vmpooler__pending__' + pool['name']).each do |vm|
            unless pool['timeout']
              if $config[:config]['timeout']
                pool['timeout'] = $config[:config]['timeout']
              else
                pool['timeout'] = 15
              end
            end

            if inventory[vm]
              begin
                check_pending_vm(vm, pool['name'], pool['timeout'])
              rescue
              end
            else
              $logger.log('d', "[*] [#{pool['name']}] #{vm} not in inventory, removing from 'pending' queue")
              $redis.srem('vmpooler__pending__' + pool['name'], vm)
              $redis.del('vmpooler__vm__' + vm)
            end
          end

          # COMPLETED
          $redis.smembers('vmpooler__completed__' + pool['name']).each do |vm|
            if inventory[vm]
              begin
                destroy_vm(vm, pool['name'])
              rescue
                $logger.log('s', "[!] [#{pool['name']}] '#{vm}' destroy appears to have failed")
                $redis.srem('vmpooler__completed__' + pool['name'], vm)
                $redis.hdel('vmpooler__active__' + pool['name'], vm)
                $redis.del('vmpooler__vm__' + vm)
              end
            else
              $logger.log('s', "[!] [#{pool['name']}] '#{vm}' not found in inventory, removed from 'completed' queue")
              $redis.srem('vmpooler__completed__' + pool['name'], vm)
              $redis.hdel('vmpooler__active__' + pool['name'], vm)
              $redis.del('vmpooler__vm__' + vm)
            end
          end

          # DISCOVERED
          $redis.smembers('vmpooler__discovered__' + pool['name']).each do |vm|
            %w(pending ready running completed).each do |queue|
              if $redis.sismember('vmpooler__' + queue + '__' + pool['name'], vm)
                $logger.log('d', "[!] [#{pool['name']}] '#{vm}' found in '#{queue}', removed from 'discovered' queue")
                $redis.srem('vmpooler__discovered__' + pool['name'], vm)
              end
            end

            if $redis.sismember('vmpooler__discovered__' + pool['name'], vm)
              $redis.smove('vmpooler__discovered__' + pool['name'], 'vmpooler__completed__' + pool['name'], vm)
            end
          end

          # LONG-RUNNING
          $redis.smembers('vmpooler__running__' + pool['name']).each do |vm|
            if $redis.hget('vmpooler__active__' + pool['name'], vm)
              running = (Time.now - Time.parse($redis.hget('vmpooler__active__' + pool['name'], vm))) / 60 / 60
              lifetime = $redis.hget('vmpooler__vm__' + vm, 'lifetime') || $config[:config]['vm_lifetime']

              if
                (lifetime.to_i > 0) &&
                (running.to_i > lifetime.to_i)

                $redis.smove('vmpooler__running__' + pool['name'], 'vmpooler__completed__' + pool['name'], vm)

                $logger.log('d', "[!] [#{pool['name']}] '#{vm}' reached end of TTL after #{lifetime} hours")
              end
            end
          end

          # REPOPULATE
          total = $redis.scard('vmpooler__ready__' + pool['name']) +
                  $redis.scard('vmpooler__pending__' + pool['name'])

          begin
            if defined? $graphite
              $graphite.log($config[:graphite]['prefix'] + '.ready.' + pool['name'], $redis.scard('vmpooler__ready__' + pool['name']))
              $graphite.log($config[:graphite]['prefix'] + '.running.' + pool['name'], $redis.scard('vmpooler__running__' + pool['name']))
            end
          rescue
          end

          if total < pool['size']
            (1..(pool['size'] - total)).each do |_i|
              if $redis.get('vmpooler__tasks__clone').to_i < $config[:config]['task_limit']
                begin
                  $redis.incr('vmpooler__tasks__clone')

                  $logger.log('d', "[*] [#{pool['name']}] attempting to clone vm")
                  clone_vm(
                    pool['template'],
                    pool['folder'],
                    pool['datastore'],
                    pool['clone_target'],
                    pool['customize']
                  )
                rescue
                  $logger.log('s', "[!] [#{pool['name']}] clone appears to have failed")
                  $redis.decr('vmpooler__tasks__clone')
                end
              end
            end
          end

          sleep(5)
        end
      end
    end

    def execute!
      $logger.log('d', 'starting vmpooler')

      # Clear out the tasks manager, as we don't know about any tasks at this point
      $redis.set('vmpooler__tasks__clone', 0)

      loop do
        $pools.each do |pool|
          if ! $threads[pool['name']]
            check_pool(pool)
          else
            unless $threads[pool['name']].alive?
              $logger.log('d', "[!] [#{pool['name']}] worker thread died, restarting")
              check_pool(pool)
            end
          end
        end

        sleep(1)
      end
    end
  end
end
