[out:xml][timeout:300];
area["admin_level"="4"]["name"="İstanbul"]->.ist;
(
  way["highway"~"^(motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|residential|unclassified|living_street)$"](area.ist);
);
(._;>;);
out body;
