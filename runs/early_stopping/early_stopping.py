import sys

import numpy as np
import pandas as pd

import click
import mlflow
from optuna import Trial

from sklearn.linear_model import Ridge
from sklearn.utils import Bunch, shuffle
from sklearn.model_selection import ShuffleSplit

from experiments import Experiment
from experiments.evaluation import CrossValidate, MOOCrossValidate
from experiments.mlflow import log_experiment
from experiments.parameter_search import param_space
from experiments.parameter_search.optuna import OptunaTuner
from problems import scale_X_y
import time

from suprb import rule, SupRB
from suprb.logging.combination import CombinedLogger
from suprb.logging.multi_objective import MOLogger
from suprb.logging.stdout import StdoutLogger
from suprb.optimizer.solution import nsga2, nsga3, spea2
from suprb.optimizer.rule import es, origin, mutation, ns
from suprb.rule.subsumption import PreferSmallerVolume, PreferLargerVolume
from suprb.solution.initialization import RandomInit
from suprb.rule.matching import OrderedBound, UnorderedBound, CenterSpread, MinPercentage
import suprb.solution.mixing_model as mixing_model

from problems import scale_X_y

random_state = 45

opt_dict = {
    "nsga2": nsga2.NonDominatedSortingGeneticAlgorithm2,
    "nsga3": nsga3.NonDominatedSortingGeneticAlgorithm3,
    "spea2": spea2.StrengthParetoEvolutionaryAlgorithm2,
}


def load_dataset(name: str, **kwargs) -> tuple[np.ndarray, np.ndarray]:
    method_name = f"load_{name}"
    from problems import datasets

    if hasattr(datasets, method_name):
        return getattr(datasets, method_name)(**kwargs)



def run_single_cycle(problem: str, job_id: str, optimizer: str) -> SupRB:

    print(f"Problem is {problem}, with job id {job_id} and optimizer {optimizer}")

    X, y = load_dataset(name=problem, return_X_y=True)
    X, y = scale_X_y(X, y)
    X, y = shuffle(X, y, random_state=random_state)

    model = SupRB(
        rule_discovery=es.ES1xLambda(
            operator="&",
            n_iter=1000,
            delay=30,
            init=rule.initialization.MeanInit(
                fitness=rule.fitness.VolumeWu(), model=Ridge(alpha=0.01, random_state=random_state)
            ),
            mutation=mutation.HalfnormIncrease(),
            origin_generation=origin.SquaredError(),
            subsumption=PreferSmallerVolume(tolerance=0.0),  
        ),
        solution_composition=opt_dict[optimizer](n_iter=32, population_size=32),
        n_iter=1000,
        n_rules=4,
        verbose=10,
        logger=CombinedLogger([("stdout", StdoutLogger()), ("default", MOLogger())]),
        random_state=random_state,
        early_stopping_patience = 10
    )



    start = time.perf_counter()
    model.fit(X, y)
    elapsed = time.perf_counter() - start
    print(f"Training took {elapsed:.2f} seconds ({elapsed / 60:.2f} minutes)")








def main():
    model = run_single_cycle("airfoil_self_noise", "NA", "spea2")
    

if __name__ == "__main__":
    main()