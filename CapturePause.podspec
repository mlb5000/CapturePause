Pod::Spec.new do |s|
  s.name         = "CapturePause"
  s.version      = "0.1"
  s.summary      = "Record-Pause-Record implementation originally provided as an example on GDCL.co.uk"
  s.homepage     = "http://www.gdcl.co.uk/2013/02/20/iPhone-Pause.html"
  s.license      = { :type => "ATTRIBUTION", :file => "LICENSE" }
  s.author       = { "Geraint Davies" => "info@gdcl.co.uk" }

  s.ios.deployment_target = "8.0"
  s.osx.deployment_target = "10.9"

  s.source       = {
    :git => "https://github.com/mlb5000/CapturePause.git",
    :tag => s.version.to_s
  }

  s.source_files = "Source/*.{h,swift}"
  s.requires_arc = true
end