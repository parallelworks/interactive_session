# Cesium Interactive Session
This workflow starts a Cesium app [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md) a **Compute Cluster** (SLURM or PBS). It requires **Rocky Linux 9**

The app is defined as an HTML. You may use the example below after replacing your access token:
```
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Cesium App</title>
    <script src="node_modules/cesium/Build/Cesium/Cesium.js"></script>
    <link href="node_modules/cesium/Build/Cesium/Widgets/widgets.css" rel="stylesheet">
    <style>
        html, body, #cesiumContainer { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; }
    </style>
</head>
<body>
    <div id="cesiumContainer"></div>
    <script>
        Cesium.Ion.defaultAccessToken = '__ACCESS_TOKEN__';
        const viewer = new Cesium.Viewer('cesiumContainer', {
            terrain: Cesium.Terrain.fromWorldTerrain()
        });
        viewer.camera.flyTo({
            destination: Cesium.Cartesian3.fromDegrees(-122.4175, 37.655, 400),
            orientation: {
                heading: Cesium.Math.toRadians(0.0),
                pitch: Cesium.Math.toRadians(-15.0)
            }
        });
        async function addBuildings() {
            const buildings = await Cesium.createOsmBuildingsAsync();
            viewer.scene.primitives.add(buildings);
        }
        addBuildings();
    </script>
</body>
</html>
```


