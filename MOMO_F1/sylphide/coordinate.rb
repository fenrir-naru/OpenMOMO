=begin
���W�n�ɂ��ċL�q�����t�@�C��
coordinate.h��ruby��
=end

$: << File::dirname(__FILE__) unless $:.include?(File::dirname(__FILE__))
require 'WGS84'

class System_3D
  def initialize(*v3)
    @buf = [0, 1, 2].collect{|i|
      v3[i] || 0.0
    }
  end
  def to_a
    @buf
  end
  
  def abs2
    return @buf.inject(0.0){|sum, v| sum + (v ** 2)}
  end
  def abs
    return Math::sqrt(abs2())
  end
  def [](i)
    @buf[i]
  end
end

class System_LLH < System_3D
  [:latitude, :longitude, :height].each_with_index{|k, i|
    class_eval(<<-__TEXT__)
      def #{k}; @buf[#{i}]; end
      def #{k}=(v); @buf[#{i}] = v; end
    __TEXT__
  }
  alias :lat :latitude
  alias :long :longitude
  alias :lng :longitude
  alias :h :height
  
  undef_method :abs2, :abs
  
  def initialize(*lat_lng_h)
    super(*lat_lng_h)
  end
end

class System_XYZ < System_3D
  EARTH = WGS84
  F = EARTH::F_E
  A = EARTH::R_E
  B = A * (1.0 - F)
  E = Math::sqrt(F * (2.0 - F))
  
  [:x, :y, :z].each_with_index{|k, i|
    class_eval(<<-__TEXT__)
      def #{k}; @buf[#{i}]; end
      def #{k}=(v); @buf[#{i}] = v; end
    __TEXT__
  }
  
  def initialize(*x_y_z)
    super(*x_y_z)
  end
  
  def dist(xyz)
    return Math::sqrt((x() - xyz.x()) ** 2 + (y() - xyz.y()) ** 2 + (z() - xyz.z()) ** 2)
  end
  
  #
  # �ܓx�A�o�x�A���x�ɕϊ�
  #
  def llh
    if x() == 0 and y() == 0 and z() == 0 then
      return System_LLH::new(0, 0, -A)
    end
    
    h = A ** 2 - B ** 2;
    p = Math::sqrt(x() ** 2 + y() ** 2)
    t = Math::atan2(z() * A, p * B)
    sint = Math::sin(t)
    cost = Math::cos(t)
    lat = Math::atan2(z() + (h / B * (sint ** 3)), p - (h / A * (cost ** 3))) 
    n = A / Math::sqrt(1.0 - (E ** 2) * (Math::sin(lat) ** 2))
    return System_LLH::new( \
        lat, \
        Math::atan2(y(), x()), \
        p / Math::cos(lat) - n)
  end
  
  def xyz
    return self
  end
end

class System_LLH
  EARTH = WGS84
  F = EARTH::F_E
  A = EARTH::R_E
  B = A * (1.0 - F)
  E = Math::sqrt(F * (2.0 - F))
  
  def llh
    return self
  end
  
  def xyz
    n = A / Math::sqrt(1.0 - (E ** 2) * (Math::sin(lat()) ** 2))
    latc, lats = [:cos, :sin].collect{|f| Math.send(f, lat())}
    lngc, lngs = [:cos, :sin].collect{|f| Math.send(f, lng())}
    return System_XYZ::new( \
        (n + h()) * latc * lngc, \
        (n + h()) * latc * lngs, \
        (n * (1.0 - (E ** 2)) + h()) * lats)
  end
end

class System_ENU < System_3D
  [:east, :north, :up].each_with_index{|k, i|
    class_eval(<<-__TEXT__)
      def #{k}; @buf[#{i}]; end
      def #{k}=(v); @buf[#{i}] = v; end
    __TEXT__
  }
  alias :e :east
  alias :n :north
  alias :u :up
  
  def initialize(*east_north_up)
    super(*east_north_up)
  end
  
  def System_ENU.relative(pos, base, options = {})
    base_llh = base.llh()
    rel_x, rel_y, rel_z = pos.xyz().to_a()
    
    unless options[:pos_is_xyz] then
      base_xyz = base.xyz()
      rel_x -= base_xyz.x()
      rel_y -= base_xyz.y()
      rel_z -= base_xyz.z()
    end
    
    s1, c1 = [:sin, :cos].collect{|f| Math.send(f, base_llh.lng())}
    s2, c2 = [:sin, :cos].collect{|f| Math.send(f, base_llh.lat())}
    
    return System_ENU::new( \
        -rel_x * s1 + rel_y * c1, \
        -rel_x * c1 * s2 - rel_y * s1 * s2 + rel_z * c2, \
        rel_x * c1 * c2 + rel_y * s1 * c2 + rel_z * s2)
  end
  
  def System_ENU.relative_rel(rel_xyz, base)
    return System_ENU.relative(rel_xyz, base, {:pos_is_xyz => true})
  end
  
  def absolute(base)
    base_llh = base.llh()
    base_xyz = base.xyz()
    
    s1, c1 = [:sin, :cos].collect{|f| Math.send(f, base_llh.lng())}
    s2, c2 = [:sin, :cos].collect{|f| Math.send(f, base_llh.lat())}
    
    return System_XYZ::new( \
        base_xyz.x() - east() * s1 - north() * c1 * s2 + up() * c1 * c2, \
        base_xyz.y() + east() * c1 - north() * s1 * s2 + up() * s1 * c2, \
        base_xyz.z() + north() * c2 + up() * s2)
  end
  
  def elevation
    return Math::atan2(up(), Math::sqrt((east() ** 2) + (north() ** 2)))
  end
  def azimuth
    return Math::atan2(east(), north())
  end
end