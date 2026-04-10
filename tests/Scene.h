#pragma once

#include <string>

namespace appgl {
class GLContext;
}

namespace appgl::tests {

struct SceneSize {
    int width = 512;
    int height = 512;
};

class Scene {
public:
    virtual ~Scene() = default;

    virtual std::string id() const = 0;
    virtual std::string phase() const = 0;
    virtual SceneSize framebufferSize() const { return {}; }
    virtual void setup(GLContext& context) = 0;
    virtual void render(GLContext& context) = 0;
    virtual double tolerance() const { return 0.01; }
};

}  // namespace appgl::tests
