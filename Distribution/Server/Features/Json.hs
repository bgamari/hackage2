module Distribution.Server.Features.Json (
    JsonFeature,
    initJsonFeature
  ) where

-- This feature will be the basis of an API with non-human user agents.
import Distribution.Server.Framework.Feature

data JsonFeature = JsonFeature

instance IsHackageFeature JsonFeature where
    getFeatureInterface _ = empytHackageFeature "json"

initJsonFeature :: CoreFeature -> IO JsonFeature
initJsonFeature _ = return JsonFeature
