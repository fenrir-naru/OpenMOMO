#!/usr/bin/ruby
# coding: cp932

$stderr.puts "Converter to Sylphide data from multiple files"
$stderr.puts " Usage: #{$0} [--key[=value]]"

[
  File::dirname(__FILE__),
].each{|dir|
  $: << dir unless $:.include?(dir)
}

opt = {
  :basetime => "2017-07-30 16:30:44 +0900", # according to https://github.com/istellartech/OpenMOMO/issues/2
  :prefix => :telem1,
  :inertial => 'sensors.csv',
  :posvel => 'ecef_ecefvel.csv',
}

ARGV.reject!{|arg|
  next false unless arg =~ /--([^=]+)=?/
  opt[$1.to_sym] = $'
  true
}

opt[:data_dir] ||= File::join(File::dirname(__FILE__), '..', 'csv', opt[:prefix].to_s)
[:inertial, :posvel].each{|k|
  opt[k] = "#{opt[:prefix]}_#{opt[k]}"
} if opt[:prefix] and ('' != opt[:prefix])

$stderr.puts "options: #{opt}"

base_week, base_itow, leapsec = proc{
  require 'time'
  require 'gpstime'
  t = GPSTime::itow(Time::parse(opt[:basetime]))
  [t[0] * 1024 + t[1], t[2], t[3]]
}.call

inertial2imu_csv = proc{|out|
  # read CSV and write [t,accelX,Y,Z,omegaX,Y,Z]
  open(File::join(opt[:data_dir], opt[:inertial])){|io|
    header = io.readline.chomp.split(/, */)
    
    index = ["T[s]",
        "ax[g]", "ay[g]", "az[g]",
        "wx[dps]", "wy[dps]", "wz[dps]"].collect{|k|
      header.index(k)
    }
    io.each{|line|
      values = line.chomp.split(/, */).values_at(*index).collect{|v| v.to_f}
      values[0] += base_itow
      out.puts values.join(',')
    }
  }
  out
}

posvel2ubx = proc{|out|
  # read CSV and write ubx format binary
  
  require 'coordinate'
  require 'ubx'
  
  open(File::join(opt[:data_dir], opt[:posvel])){|io|
    header = io.readline.chomp.split(/, */)
    index_t = header.index("T[s]")
    index_pos, index_vel, index_posacc, index_velacc = [
      ["ecef_x[m]","ecef_y[m]","ecef_z[m]"],
      ["ecef_vx[m/s]","ecef_vy[m/s]","ecef_vz[m/s]"],
      ["ecef_x_acc[m]","ecef_y_acc[m]","ecef_z_acc[m]"],
      ["ecef_vx_acc[m/s]","ecef_vy_acc[m/s]","ecef_vz_acc[m/s]"],
    ].collect{|k_s| 
      k_s.collect{|k| header.index(k)}
    }
    index_posacc = nil unless index_posacc.all?
    index_velacc = nil unless index_velacc.all?
    
    timegps = proc{
      t_previous = 0
      proc{|t|
        t_int = t.to_i
        next if t_int == t_previous
        t_previous = t_int
        
        ubx_time = [0xB5, 0x62, 0x01, 0x20, 16, t_int * 1000].pack('c4vV')
        ubx_time << [
            0, # Nanoseconds remainder
            base_week, # GPS week
            leapsec, # Leap sec
            0x07, # Valid
            10_000, # TAcc [ns] => 10 us
            ].pack('l<s<cCV')
        ubx_time << UBX::checksum(ubx_time.unpack('c*'), 2..-1).pack('c2')
        out.print ubx_time
      }
    }.call
    
    io.each{|line|
      values = line.chomp.split(/, */)
      t = values[index_t].to_f + base_itow
      pos_ecef, vel_ecef = [index_pos, index_vel].collect{|index|
        System_XYZ::new(*(values.values_at(*index).collect{|str| str.to_f}))
      }
      pos_llh = pos_ecef.llh
      vel_enu = System_ENU.relative_rel(vel_ecef, pos_ecef)
    
      # 精度関係の処理
      acc = {
        :pAcc_cm => 1200,
        :hAcc_mm => 3000,
        :vAcc_mm => 10000,
        :sAcc_cms => 50,
        :cAcc_deg => 0.5,
      }
      
      if index_posacc then
        posacc = values.values_at(*index_posacc).collect{|str| str.to_f}
        acc[:pAcc_cm] = Math::sqrt(posacc.collect{|v|
          (1E2 * v.to_f) ** 2 # m => cm^2
        }.inject{|memo, v| memo + v})
        posacc_enu = System_ENU.relative_rel(System_XYZ::new(*posacc), pos_ecef)
        acc[:hAcc_mm] = Math::sqrt((posacc_enu[0] ** 2) + (posacc_enu[1] ** 2))
        acc[:vAcc_mm] = posacc_enu[2].abs
      end
      
      if index_velacc then
        velacc = values.values_at(*index_velacc).collect{|str| str.to_f}
        acc[:sAcc_cms] = Math::sqrt(velacc.collect{|v|
          (1E2 * v.to_f) ** 2 # m => cm^2
        }.inject{|memo, v| memo + v})
      end
      
      # 0x01 0x20/0x06/0x02/0x12 が必要
      itow = [(1E3 * t).to_i].pack('V')
      
      # NAV-TIMEGPS (0x01-0x20)
      timegps.call(t)
      
      # NAV-SOL (0x01-0x06)
      ubx_sol = [0xB5, 0x62, 0x01, 0x06, 52].pack('c4v') + itow
      ubx_sol << [
          0, # frac
          base_week, # week
          0x03, # 3D-Fix
          0x0D, # GPSfixOK, WKNSET, TOWSET
          pos_ecef.to_a.collect{|v| (v * 1E2).to_i}, # ECEF_XYZ [cm]
          acc[:pAcc_cm].to_i, # 3D pos accuracy [cm]
          vel_ecef.to_a.collect{|v| (v * 1E2).to_i}, # ECEF_VXYZ [cm/s]
          acc[:sAcc_cms].to_i, # Speed accuracy [cm/s]
          [0] * 8].flatten.pack('Vvc2l<3Vl<3Vc8')
      ubx_sol << UBX::checksum(ubx_sol.unpack('c*'), 2..-1).pack('c2')
      out.print ubx_sol
      
      # NAV-POSLLH (0x01-0x02)
      ubx_posllh = [0xB5, 0x62, 0x01, 0x02, 28].pack('c4v') + itow
      ubx_posllh << [
          (pos_llh.lng / Math::PI * 180 * 1E7).to_i, # 経度 [1E-7 deg]
          (pos_llh.lat / Math::PI * 180 * 1E7).to_i, # 緯度 [1E-7 deg]
          (pos_llh.h * 1E3).to_i, # 楕円高度 [mm]
          0, # 平均海面高度
          acc[:hAcc_mm].to_i, # HAcc [mm]
          acc[:vAcc_mm].to_i, # VAcc [mm]
          ].pack('V*')
      ubx_posllh << UBX::checksum(ubx_posllh.unpack('c*'), 2..-1).pack('c2')
      out.print ubx_posllh
      
      # NAV-VELNED (0x01-0x12)
      speed_pow2 = vel_enu.abs2
      speed_2D = Math::sqrt(speed_pow2 - (vel_enu.u ** 2))
      speed_dir = Math::atan2(vel_enu.e, vel_enu.n)
      ubx_velned = [0xB5, 0x62, 0x01, 0x12, 36].pack('c4v') + itow
      ubx_velned << [
          (vel_enu.n * 1E2).to_i, # N方向速度 [cm/s]
          (vel_enu.e * 1E2).to_i, # E方向速度 [cm/s]
          (-vel_enu.u * 1E2).to_i, # D方向速度 [cm/s]
          (Math::sqrt(speed_pow2) * 1E2).to_i, # 3D速度 [cm/s]
          (speed_2D * 1E2).to_i, # 2D速度 [cm/s]
          (speed_dir / Math::PI * 180 * 1E5).to_i, # ヘディング [1E-5 deg]
          acc[:sAcc_cms].to_i, # sAcc 速度精度 [cm/s]
          (acc[:cAcc_deg] * 1E5).to_i, # cAcc ヘディング精度 [1E-5 deg]
          ].pack('V*')
      ubx_velned << UBX::checksum(ubx_velned.unpack('c*'), 2..-1).pack('c2')
      out.print ubx_velned
    }
  }
  out
}

#inertial2imu_csv.call($stdout)
#posvel2ubx.call($stdout)

require 'tempfile'
data_mod = Hash[*({:inertial => inertial2imu_csv, :posvel => posvel2ubx}.collect{|k, f|
  out = f.call(Tempfile::open(File::basename(__FILE__, '.*'), mode: File::BINARY))
  out.close
  [k, out]
}.flatten(1))]

$stderr.puts data_mod.inspect

require 'log_mixer'
log_prop = {
  :readers => [
    IMU_CSV::new(data_mod[:inertial].open, { # Simulate MPU-6000/9250 of NinjaScan (FS: 8G, 2000dps)
      :acc_units => [9.80665] * 3, # G => m/s
      :acc_bias => [1 << 15] * 3, # Full scale is 16 bits
      :acc_sf => [(1<<15).to_f / (9.80665 * 8)] * 3, # 8[G] full scale; [1/(m/s^2)]
      :gyro_units => [Math::PI / 180] * 3, # dps => rad/s
      :gyro_bias => [1 << 15] * 3, # Full scale is 16 bits
      :gyro_sf => [(1<<15).to_f / (Math::PI / 180 * 2000)] * 3, # 2000[dps] full scale; [1/(rad/s)]
    }),
    GPS_UBX::new(data_mod[:posvel].open), 
  ],
}
STDOUT.binmode
$log_mix.call(log_prop.merge({:out => $stdout}))
